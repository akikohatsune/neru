#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

OUTPUT_NAME="${1:-neru}"

LIT_BIN="lit"
if command -v lit >/dev/null 2>&1; then
  LIT_BIN="lit"
elif [[ -x "${PROJECT_ROOT}/lit" ]]; then
  LIT_BIN="${PROJECT_ROOT}/lit"
else
  echo "lit command not found. Bootstrapping local lit/luvi/luvit..."
  bash "${PROJECT_ROOT}/scripts/bootstrap-luvit.sh"
  if [[ -x "${PROJECT_ROOT}/lit" ]]; then
    LIT_BIN="${PROJECT_ROOT}/lit"
  else
    echo "Bootstrap failed: lit still missing." >&2
    exit 1
  fi
fi

"${LIT_BIN}" install
"${LIT_BIN}" make . "${OUTPUT_NAME}"
chmod +x "${OUTPUT_NAME}" || true

if [[ ! -f "${OUTPUT_NAME}" ]]; then
  echo "Build failed: output not found (${OUTPUT_NAME})" >&2
  exit 1
fi

echo "Built ${OUTPUT_NAME}"
