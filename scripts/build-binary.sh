#!/usr/bin/env bash
set -euo pipefail

OUTPUT_NAME="${1:-neru}"

LIT_BIN="lit"
if command -v lit >/dev/null 2>&1; then
  LIT_BIN="lit"
elif [[ -x "./lit" ]]; then
  LIT_BIN="./lit"
else
  echo "lit command not found. Install lit/luvi first." >&2
  exit 1
fi

"${LIT_BIN}" install
"${LIT_BIN}" make . "${OUTPUT_NAME}"
chmod +x "${OUTPUT_NAME}" || true

if [[ ! -f "${OUTPUT_NAME}" ]]; then
  echo "Build failed: output not found (${OUTPUT_NAME})" >&2
  exit 1
fi

echo "Built ${OUTPUT_NAME}"
