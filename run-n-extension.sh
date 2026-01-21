#!/bin/bash
# Run flaky test experiment on a cluster using Apptainer container
# Usage: bash experiment_in_unicorn.sh <row-file> <output-dir> [runs=1000] [scratch-base]
# Environment variables: START_RUN (default 1), START_MODE (default baseline)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ROW_FILE="${1:-}"
OUT_DIR="${2:-}"
RUNS="${3:-1000}"
SCR="${4:-/scratch/${USER}/${SLURM_JOB_ID:-manual}}"
START_RUN="${START_RUN:-1}"

[[ -n "$ROW_FILE" && -f "$ROW_FILE" && -n "$OUT_DIR" ]] || {
  echo "Usage: bash experiment_in_unicorn.sh <row-file> <output-dir> [runs] [scratch-base]"
  exit 1
}

mkdir -p "$OUT_DIR" "$SCR"
cp "$ROW_FILE" "$SCR/row.csv"

APPTAINER_BIN="${APPTAINER_BIN:-/share/apps/software/apptainer/apptainer-1.4.0/bin/apptainer}" # unicorn path
[[ -x "$APPTAINER_BIN" ]] || APPTAINER_BIN="apptainer"

# Find SIF image or use Docker URI fallback
SIF="${FLAKY_RV_SIF:-}"
URI="${APPTAINER_IMAGE_FALLBACK_URI:-docker://jooney/flaky-rv-trace-compression:module-fix}"
CACHEDIR="${APPTAINER_CACHEDIR:-/scratch/${USER}/apptainer-cache}"
TMPDIR="${APPTAINER_TMPDIR:-/scratch/${USER}/apptainer-tmp}"

mkdir -p "$CACHEDIR" "$TMPDIR"
export APPTAINER_CACHEDIR="$CACHEDIR" APPTAINER_TMPDIR="$TMPDIR"

if [[ -n "$SIF" && -f "$SIF" ]]; then
  IMAGE="$SIF"
else
  IMAGE="$URI"
fi

echo "Host: $(hostname)"
echo "Scratch: $SCR"
echo "Output: $OUT_DIR"
echo "Runs: $RUNS"
echo "Image: $IMAGE"
[[ "$START_RUN" -gt 1 ]] && echo "Resume from: run $START_RUN"
echo ""

set +e
"$APPTAINER_BIN" exec \
  --bind "$SCR:/work" \
  --bind "$OUT_DIR:/out" \
  --env RUNS_VAL="$RUNS" \
  --env START_RUN="$START_RUN" \
  "$IMAGE" \
  bash -lc 'set -euo pipefail
LINE="$(cat /work/row.csv)"
WORK_DIR=/work/run
OUT=/out

# the /home/tracemop/flaky-scripts is read-only, so we need to copy it to the scratch space to git pull
IMG_SCRIPTS="/home/tracemop/flaky-scripts"
WRITABLE_SCRIPTS="/work/flaky-scripts"

mkdir -p "$WORK_DIR" "$OUT"
cd "$WORK_DIR"

export MAVEN_OPTS="-Dmaven.repo.local=/work/.m2"
export PATH="/home/tracemop/apache-maven/bin:$PATH"

echo "CSV: $LINE"

rm -rf "$WRITABLE_SCRIPTS"
cp -r "$IMG_SCRIPTS" "$WRITABLE_SCRIPTS"

# Update scripts (Verbose)
echo ">> Updating scripts..."
cd "$WRITABLE_SCRIPTS"
git pull || echo "WARNING: git pull failed (using image version)"
echo "Flaky-RV Scripts SHA: $(git rev-parse HEAD)"
cd "$WORK_DIR"

# Execute
echo ">> Clone..."
bash "$WRITABLE_SCRIPTS/pull-and-checkout.sh" "$LINE"

echo ">> Run tests..."
bash "$WRITABLE_SCRIPTS/run-n-extension.sh" "$LINE" "$RUNS_VAL" "$OUT"

echo ">> Done"
'
rc=$?
set -e

echo "Container exit code: $rc"
exit "$rc"