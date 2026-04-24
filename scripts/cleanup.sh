#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE_DIR="${ROOT_DIR}/.state"
ARTIFACTS_DIR="${ROOT_DIR}/artifacts"
KARMADA_APISERVER_PROXY_PID_FILE="${STATE_DIR}/karmada-apiserver-port-forward.pid"
PROJECT_CLUSTERS=(karmada-host member1 member2)
CLEAN_KARMADA_SOURCE="${CLEAN_KARMADA_SOURCE:-false}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd kind

if [[ -f "${KARMADA_APISERVER_PROXY_PID_FILE}" ]]; then
  proxy_pid=$(cat "${KARMADA_APISERVER_PROXY_PID_FILE}" 2>/dev/null || true)
  if [[ -n "${proxy_pid}" ]] && kill -0 "${proxy_pid}" 2>/dev/null; then
    echo "Stopping local karmada-apiserver port-forward: ${proxy_pid}"
    kill "${proxy_pid}" 2>/dev/null || true
  fi
fi

for cluster in "${PROJECT_CLUSTERS[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "${cluster}"; then
    echo "Deleting kind cluster: ${cluster}"
    kind delete cluster --name "${cluster}"
  else
    echo "Cluster not present: ${cluster}"
  fi
done

rm -rf "${STATE_DIR}"
mkdir -p "${ARTIFACTS_DIR}"

if [[ "${CLEAN_KARMADA_SOURCE}" == "true" ]]; then
  echo "Removing fetched upstream source checkout: ${ROOT_DIR}/karmada"
  rm -rf "${ROOT_DIR}/karmada"
fi

cat <<EOF

Cleanup complete.
- Removed generated state under: ${STATE_DIR}
- Preserved proof artifacts under: ${ARTIFACTS_DIR}
- Preserved fetched Karmada source checkout (set CLEAN_KARMADA_SOURCE=true to remove it)

Remaining kind clusters:
EOF
kind get clusters || true
