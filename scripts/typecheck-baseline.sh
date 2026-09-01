#!/usr/bin/env bash
set -euo pipefail

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

status=0
./node_modules/.bin/tsc --noEmit --pretty false >"$report" 2>&1 || status=$?
if (( status != 0 && status != 2 )); then
  echo "TypeScript failed before producing a usable baseline report." >&2
  exit "$status"
fi

errors="$(grep -c 'error TS' "$report" || true)"
if (( errors == 0 && status != 0 )); then
  echo "TypeScript failed without recognized diagnostics." >&2
  exit 1
fi
if (( errors > 65 )); then
  echo "Legacy contract TypeScript baseline regressed: ${errors} errors; maximum 65." >&2
  exit 1
fi

echo "Legacy contract TypeScript baseline accepted: ${errors} errors. Contract logic was not redesigned in P0."
