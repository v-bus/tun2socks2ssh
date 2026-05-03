#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
make check
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x bin/*.sh packaging/*.sh
else
  echo "shellcheck not installed, skipping"
fi
echo "tests/check-scripts.sh OK"
