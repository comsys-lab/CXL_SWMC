#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LMDB_DIR="${LMDB_DIR:-${ROOT_DIR}/third_party/LMDB}"
JOBS="${JOBS:-$(nproc)}"
INSTALL_DEPS="${INSTALL_DEPS:-0}"
SKIP_SUDO_INSTALL="${SKIP_SUDO_INSTALL:-0}"

if [[ ! -d "${LMDB_DIR}" ]]; then
  echo "LMDB directory not found at: ${LMDB_DIR}" >&2
  exit 1
fi

if [[ "${INSTALL_DEPS}" == "1" ]]; then
  echo "[setup] Installing dependencies (libsnappy-dev)..."
  sudo apt-get update
  sudo apt-get install -y libsnappy-dev
fi

echo "[setup] Building LMDB library..."
pushd "${LMDB_DIR}/libraries/liblmdb" >/dev/null
make -j"${JOBS}"
if [[ "${SKIP_SUDO_INSTALL}" == "1" ]]; then
  echo "[setup] SKIP_SUDO_INSTALL=1, skipping 'sudo make install'."
  echo "[setup] Note: dbbench link may fail if liblmdb is not discoverable by linker."
else
  sudo make install
  sudo ldconfig
fi
popd >/dev/null

echo "[setup] Building dbbench (t_lmdb)..."
pushd "${LMDB_DIR}/dbbench" >/dev/null
make clean
make -j"${JOBS}"
popd >/dev/null

echo "[setup] Done. Binary path: ${LMDB_DIR}/dbbench/bin/t_lmdb"
