#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <csv-line> <runs-per-mode> <out-root>"
  exit 1
fi

line="$1"; runs="$2"; OUT_ROOT="$3"
START_VARIANT="${START_VARIANT:-}"; START_RUN="${START_RUN:-1}"
case "$START_VARIANT" in ""|baseline|javamop|tracemop) ;; *) echo "Invalid START_VARIANT"; exit 1 ;; esac
[[ "$runs" =~ ^[0-9]+$ && "$runs" -ge 1 ]] || { echo "runs must be >=1"; exit 1; }
[[ "$START_RUN" =~ ^[0-9]+$ && "$START_RUN" -ge 1 ]] || { echo "START_RUN must be >=1"; exit 1; }
[[ -z "$START_VARIANT" && "$START_RUN" -gt 1 ]] && START_VARIANT=baseline
[[ -n "$START_VARIANT" ]] && echo "[resume] $START_VARIANT from run $START_RUN"

EXT="/home/tracemop/tracemop/extensions/javamop-extension-1.0.jar"
AG_JAVA="/home/tracemop/tracemop/scripts/no-track-no-stats-agent.jar"
AG_TRACE="/home/tracemop/tracemop/scripts/track-no-stats-agent.jar"

IFS=',' read -r REPO_URL SHA MODULE_PATH FQ_TEST _ <<<"$line"
REPO_DIR="$(basename "$REPO_URL" .git)"
CLASS_FQ="${FQ_TEST%.*}"; METHOD="${FQ_TEST##*.}"
SEL="${CLASS_FQ}#${METHOD}"; SEL_WC="${SEL}*"

cd "$REPO_DIR"; git checkout "$SHA" >/dev/null

mkdir -p "$OUT_ROOT"

# Prepare Maven flags
MVN_MODULE_FLAGS="-Dsurefire.failIfNoSpecifiedTests=false"
if [[ -n "$MODULE_PATH" && "$MODULE_PATH" != "." ]]; then
  MVN_MODULE_FLAGS="-pl ${MODULE_PATH} -am ${MVN_MODULE_FLAGS}"
fi

no_tests_found() { grep -qE "No tests|Tests run: 0," "$1"; }
cleanup_violations() { find "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" -name "violation-counts*" -type f -delete 2>/dev/null || true; }
copy_violations() { rm -f "$1"/violation-counts* 2>/dev/null || true; find . -name "violation-counts*" -type f -exec cp {} "$1/" \; 2>/dev/null || true; }

run_mvn() {
  local mode="$1" sel="$2" run_dir="$3"
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
  echo "[${mode}] ${sel}"
  set +e
  
  # August is goated: -DfailIfNoTests=true (covered by surefire flag), -Dmaven.test.failure.ignore (we want to fail on assertion errors)
  env "${envs[@]}" mvn -Dmaven.ext.class.path="$EXT" \
      $MVN_MODULE_FLAGS \
      -DskipTests=false \
      -Dmaven.test.skip=false \
      -Dtest="$sel" test >>"$logfile" 2>&1
  
  rc=$?
  set -e
  summary="$(grep -E "Tests run:" "$logfile" | tail -n 1 || true)"; [[ -z "$summary" ]] && summary="No summary found"
  printf "STATUS=%s\nSUMMARY=%s\nTEST_SELECTOR=%s\n" "$rc" "$summary" "$sel" > "${run_dir}/result.txt"
  [[ "$mode" =~ ^(javamop|tracemop)$ ]] && copy_violations "$run_dir"
  return $rc
}

modes=(baseline javamop tracemop)
started=0
for mode in "${modes[@]}"; do
  if [[ -n "$START_VARIANT" && "$started" -eq 0 ]]; then
    if [[ "$mode" != "$START_VARIANT" ]]; then continue; fi
    start_i="$START_RUN"; started=1
  else
    start_i=1
  fi

  if [[ "$mode" == "baseline" ]]; then
    if [[ "$start_i" -le 1 ]]; then
      base_dir="${OUT_ROOT}/baseline/run-1"
      if ! run_mvn baseline "$SEL" "$base_dir"; then
        if no_tests_found "${base_dir}/mvn.log"; then
          echo "[baseline] no tests matched; retrying wildcard: ${SEL_WC}"
          SEL="$SEL_WC"
          run_mvn baseline "$SEL" "$base_dir" || true
        fi
      fi
      start_i=2
    fi
    for i in $(seq "$start_i" "$runs"); do
      echo "[baseline] run ${i}/${runs}"
      run_mvn baseline "$SEL" "${OUT_ROOT}/baseline/run-${i}" || true
    done
    continue
  fi

  for i in $(seq "$start_i" "$runs"); do
    echo "[${mode}] run ${i}/${runs}"
    run_mvn "$mode" "$SEL" "${OUT_ROOT}/${mode}/run-${i}" || true
    if [[ "$mode" == "tracemop" && -d "${OUT_ROOT}/tracemop/run-${i}/all-traces" ]]; then
      echo "[tracemop] compressing all-traces for run-${i}"
      tar -C "${OUT_ROOT}/tracemop/run-${i}" -czf "${OUT_ROOT}/tracemop/run-${i}/all-traces.tar.gz" all-traces
      rm -rf "${OUT_ROOT}/tracemop/run-${i}/all-traces" || true
    fi
  done
done

# Final sweep
if compgen -G "${OUT_ROOT}/tracemop/run-*/all-traces" > /dev/null; then
  echo "Compressing tracemop all-traces per run..."
  for run_dir in "${OUT_ROOT}"/tracemop/run-*; do
    [[ -d "${run_dir}/all-traces" ]] || continue
    echo " - $(basename "${run_dir}")/all-traces -> all-traces.tar.gz"
    tar -C "${run_dir}" -czf "${run_dir}/all-traces.tar.gz" all-traces
    rm -rf "${run_dir}/all-traces" || true
  done
fi

echo "Outputs under ${OUT_ROOT}/{baseline,javamop,tracemop}/run-*/"
