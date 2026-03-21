#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE_DIR="${ROOT_DIR}/.state"
KUBECONFIG_DIR="${STATE_DIR}/kubeconfig"
HOST_KUBECONFIG="${KUBECONFIG_DIR}/karmada.config"
MEMBER_KUBECONFIG="${KUBECONFIG_DIR}/members.config"

echo "== kind clusters =="
kind get clusters || true

echo
echo "== docker node containers =="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | (head -n 1; grep -E 'karmada-host|member1|member2' || true)

if [[ -f "${HOST_KUBECONFIG}" ]]; then
  echo
  echo "== host cluster pods =="
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-host get pods -A || true
fi

if [[ -f "${HOST_KUBECONFIG}" ]]; then
  echo
  echo "== karmada registered clusters =="
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get clusters.cluster.karmada.io || true
fi

if [[ -f "${MEMBER_KUBECONFIG}" ]]; then
  for ctx in member1 member2; do
    echo
    echo "== nodes in ${ctx} =="
    kubectl --kubeconfig "${MEMBER_KUBECONFIG}" --context "${ctx}" get nodes || true
  done
fi
