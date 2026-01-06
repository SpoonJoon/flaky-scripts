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

if [[ -n "$MODULE_PATH" && "$MODULE_PATH" != "." ]]; then
  cd "$MODULE_PATH"
fi

# Prefetch dependencies
mvn -q -DskipTests -DskipITs test-compile || true

echo "Ready at: $(pwd)"
