#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <csv-line> <runs> <out-root>"
  exit 1
fi

line="$1"; runs="$2"; OUT_ROOT="$3"
[[ "$runs" =~ ^[0-9]+$ && "$runs" -ge 1 ]] || { echo "runs must be >=1"; exit 1; }

# Resume from env var (set by cluster script based on NFS state)
START_RUN="${START_RUN:-1}"
[[ "$START_RUN" -gt 1 ]] && echo "[resume] starting from run ${START_RUN}"

EXT="/home/tracemop/tracemop/extensions/javamop-extension-1.0.jar"
AG_JAVA="/home/tracemop/tracemop/scripts/no-track-no-stats-agent.jar"
AG_TRACE="/home/tracemop/tracemop/scripts/track-no-stats-agent.jar"

# Parse CSV - FQ_TEST column is ignored for suite runs
IFS=',' read -r REPO_URL SHA MODULE_PATH FQ_TEST _ <<<"$line"
REPO_DIR="$(basename "$REPO_URL" .git)"

cd "$REPO_DIR"  # checkout already done by pull-and-checkout-suite.sh

mkdir -p "$OUT_ROOT"

cleanup_violations() { find "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" -name "violation-counts*" -type f -delete 2>/dev/null || true; }
copy_violations() { rm -f "$1"/violation-counts* 2>/dev/null || true; find . -name "violation-counts*" -type f -exec cp {} "$1/" \; 2>/dev/null || true; }

run_mvn() {
  local mode="$1" run_dir="$2"
  local logfile
  logfile="${run_dir}/mvn.log"
  cleanup_violations; mkdir -p "$run_dir"; : > "$logfile"
  case "$mode" in
    baseline) envs=(ADD_AGENT=0) ;;
    javamop)  envs=(ADD_AGENT=1 MOP_AGENT_PATH="-javaagent:${AG_JAVA}" RVMLOGGINGLEVEL=UNIQUE) ;;
    tracemop)
      mkdir -p "${run_dir}/all-traces"
      printf "db=memory\ndumpDB=false\n" > "${run_dir}/.trace-db.config"
      envs=(ADD_AGENT=1 MOP_AGENT_PATH="-javaagent:${AG_TRACE}" RVMLOGGINGLEVEL=UNIQUE COLLECT_MONITORS=1 COLLECT_TRACES=1 TRACEDB_PATH="${run_dir}/all-traces" TRACEDB_CONFIG_PATH="${run_dir}/.trace-db.config")
      ;;
  esac
  echo "[${mode}] running full test suite"
  set +e

  env "${envs[@]}" mvn -Dmaven.ext.class.path="$EXT" \
      -DskipTests=false \
      -Dmaven.test.skip=false \
      -Dgpg.skip=true \
      -Pall \
      -fae \
      test >>"$logfile" 2>&1

  rc=$?
  set -e
  summary="$(grep -E "Tests run:" "$logfile" | tail -n 1 || true)"; [[ -z "$summary" ]] && summary="No summary found"
  printf "STATUS=%s\nSUMMARY=%s\n" "$rc" "$summary" > "${run_dir}/result.txt"
  [[ "$mode" =~ ^(javamop|tracemop)$ ]] && copy_violations "$run_dir"
  return $rc
}

# Mode order for interleaving - all three run per iteration to reduce system load sensitivity
modes=(baseline javamop tracemop)

# Main interleaved loop: for each run, execute all three modes
for run_num in $(seq "$START_RUN" "$runs"); do
  for mode in "${modes[@]}"; do
    run_dir="${OUT_ROOT}/run-${run_num}/${mode}"
    echo "[run ${run_num}/${runs}] ${mode}"

    run_mvn "$mode" "$run_dir" || true

    # Compress tracemop traces immediately to save space
    if [[ "$mode" == "tracemop" && -d "${run_dir}/all-traces" ]]; then
      echo "[tracemop] compressing all-traces for run-${run_num}"
      tar -C "$run_dir" -czf "${run_dir}/all-traces.tar.gz" all-traces
      rm -rf "${run_dir}/all-traces" || true
    fi
  done
done

echo "[done] Outputs under ${OUT_ROOT}/run-*/{baseline,javamop,tracemop}/"
