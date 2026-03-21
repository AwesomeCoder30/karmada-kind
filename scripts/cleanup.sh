#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE_DIR="${ROOT_DIR}/.state"
KUBECONFIG_DIR="${STATE_DIR}/kubeconfig"

clusters=(karmada-host member1 member2)

for cluster in "${clusters[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "${cluster}"; then
    echo "Deleting kind cluster: ${cluster}"
    kind delete cluster --name "${cluster}"
  fi
done

mkdir -p "${STATE_DIR}"
rm -rf "${KUBECONFIG_DIR}"

echo
echo "Remaining kind clusters:"
kind get clusters || true
