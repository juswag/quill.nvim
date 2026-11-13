#!/usr/bin/env sh
# Runs every headless suite in tests/test_*.lua; exits non-zero if any test fails.
set -e
cd "$(dirname "$0")"
NVIM=${NVIM:-nvim}
for suite in tests/test_*.lua; do
  "$NVIM" --headless -u NONE -i NONE -l "$suite"
done
