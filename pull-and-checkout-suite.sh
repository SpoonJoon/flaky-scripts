#!/usr/bin/env bash
# Clone repo and checkout latest SHA on default branch (ignores SHA column in CSV)
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <csv-line>"
  exit 1
fi

line="$1"
IFS=',' read -r REPO_URL SHA MODULE_PATH FQ_TEST CATEGORY STATUS PR_LINK NOTES <<<"$line"
REPO_DIR="$(basename "$REPO_URL" .git)"

if [[ -d "$REPO_DIR/.git" ]]; then
  echo "Reusing existing repo $REPO_DIR"
  cd "$REPO_DIR"
  git fetch --all
else
  git clone "$REPO_URL" "$REPO_DIR"
  cd "$REPO_DIR"
fi

# Use latest SHA on default branch
DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")"
git checkout "$DEFAULT_BRANCH"
git pull origin "$DEFAULT_BRANCH"
echo "Using latest SHA: $(git rev-parse HEAD)"

MVN_MODULE_FLAGS=""
if [[ -n "$MODULE_PATH" && "$MODULE_PATH" != "." ]]; then
  MVN_MODULE_FLAGS="-pl ${MODULE_PATH} -am"
fi

echo "installing modules with flags: $MVN_MODULE_FLAGS also (skipping tests)..."

mvn $MVN_MODULE_FLAGS \
    -DskipTests=true \
    -Dgpg.skip=true \
    -B \
    install

echo "Ready at: $(pwd)"
