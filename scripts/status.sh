#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE_DIR="${ROOT_DIR}/.state"
KUBECONFIG_DIR="${STATE_DIR}/kubeconfig"
HOST_KUBECONFIG="${KUBECONFIG_DIR}/karmada.config"
MEMBERS_KUBECONFIG="${KUBECONFIG_DIR}/members.config"
CLUSTER_PATTERN='^(karmada-host|member1|member2)-(control-plane|worker|worker2|worker3)$'

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd kind
need_cmd docker
need_cmd kubectl

print_section() {
  echo
  echo "== $1 =="
}

print_section "context guide"
echo "host cluster context:      karmada-host"
echo "karmada API context:       karmada-apiserver"
echo "member cluster contexts:   member1, member2"
echo ""
echo "Use karmada-host for host cluster resources (nodes/pods/services)."
echo "Use karmada-apiserver for Karmada CRDs (clusters, policies, search, works)."

print_section "kind clusters"
kind get clusters || true

print_section "docker node containers"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | (head -n 1; grep -E 'karmada-host|member1|member2' || true)

print_section "node container count"
docker ps --format '{{.Names}}' | grep -E "${CLUSTER_PATTERN}" | wc -l | awk '{print "expected=12 observed=" $1}'

print_section "node memory limits"
if docker ps --format '{{.Names}}' | grep -E -q "${CLUSTER_PATTERN}"; then
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    echo "${node} $(docker inspect -f '{{.HostConfig.Memory}}' "${node}")"
  done < <(docker ps --format '{{.Names}}' | grep -E "${CLUSTER_PATTERN}" | sort)
else
  echo "No project node containers found."
fi

if [[ -f "${HOST_KUBECONFIG}" ]]; then
  print_section "host nodes"
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-host get nodes || true

  print_section "host cluster pods"
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-host get pods -A || true

  print_section "karmada registered clusters"
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get clusters.cluster.karmada.io || true

  print_section "karmada api resources"
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver api-resources | grep -E 'cluster.karmada.io|policy.karmada.io|work.karmada.io|search.karmada.io' || true

  print_section "karmada api services"
  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get apiservices | grep -E 'karmada.io|metrics.k8s.io' || true
else
  print_section "host kubeconfig"
  echo "Missing: ${HOST_KUBECONFIG}"
fi

if [[ -f "${MEMBERS_KUBECONFIG}" ]]; then
  for ctx in member1 member2; do
    print_section "nodes in ${ctx}"
    kubectl --kubeconfig "${MEMBERS_KUBECONFIG}" --context "${ctx}" get nodes || true
  done
else
  print_section "members kubeconfig"
  echo "Missing: ${MEMBERS_KUBECONFIG}"
fi
