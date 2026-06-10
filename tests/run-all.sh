#!/usr/bin/env bash
# tests/run-all.sh — run every test-*.sh in this directory; exit non-zero if
# any fails. Same entry point locally and in CI.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
RAN=0

for t in "$TESTS_DIR"/test-*.sh; do
  [ -f "$t" ] || continue
  RAN=$((RAN + 1))
  echo "── ${t##*/}"
  if ! bash "$t"; then
    FAILED=$((FAILED + 1))
  fi
  echo
done

echo "════ $RAN test files, $FAILED failed"
[ "$FAILED" -eq 0 ]
