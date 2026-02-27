#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
else
  FORCE=0
fi

if [[ ${FORCE} -eq 0 && -x "./lit" && -x "./luvi" && -x "./luvit" ]]; then
  echo "lit/luvi/luvit already exist in project root. Skip bootstrap."
  exit 0
fi

if ! command -v uname >/dev/null 2>&1; then
  echo "uname is required to detect platform." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "curl or wget is required to download luvit toolchain." >&2
  exit 1
fi

LUVI_VERSION="${LUVI_VERSION:-2.14.0}"
LIT_VERSION="${LIT_VERSION:-3.8.5}"
LUVI_ARCH="$(uname -s)_$(uname -m)"
LUVI_URL="https://github.com/luvit/luvi/releases/download/v${LUVI_VERSION}/luvi-regular-${LUVI_ARCH}"
LIT_URL="https://lit.luvit.io/packages/luvit/lit/v${LIT_VERSION}.zip"

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --silent --show-error -o "${out}" "${url}"
  else
    wget -qO "${out}" "${url}"
  fi
}

echo "Downloading ${LUVI_URL} -> luvi"
download "${LUVI_URL}" "luvi"
chmod +x luvi

echo "Downloading ${LIT_URL} -> lit.zip"
download "${LIT_URL}" "lit.zip"

echo "Building lit"
./luvi lit.zip -- make lit.zip lit luvi
rm -f lit.zip

echo "Building luvit"
./lit make lit://luvit/luvit luvit luvi

chmod +x lit luvi luvit
echo "Bootstrap complete: ./lit ./luvi ./luvit"
