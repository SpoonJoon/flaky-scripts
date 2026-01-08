#!/usr/bin/env bash
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

git checkout "$SHA"

MVN_MODULE_FLAGS="-Dsurefire.failIfNoSpecifiedTests=false"

if [[ -n "$MODULE_PATH" && "$MODULE_PATH" != "." ]]; then
  MVN_MODULE_FLAGS="-pl ${MODULE_PATH} -am ${MVN_MODULE_FLAGS}"
fi

echo "installing modules with flags: $MVN_MODULE_FLAGS also (skipping tests)..."

mvn $MVN_MODULE_FLAGS \
    -DskipTests=true \
    install

echo "Ready at: $(pwd)"
