#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARTIFACTS_DIR="${ROOT_DIR}/artifacts"
STATE_DIR="${ROOT_DIR}/.state"
KUBECONFIG_DIR="${STATE_DIR}/kubeconfig"
HOST_KUBECONFIG="${KUBECONFIG_DIR}/karmada.config"
MEMBERS_KUBECONFIG="${KUBECONFIG_DIR}/members.config"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="${ARTIFACTS_DIR}/${STAMP}"
LATEST_LINK="${ARTIFACTS_DIR}/latest"
CLUSTER_PATTERN='^(karmada-host|member1|member2)-(control-plane|worker|worker2|worker3)$'

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd date
need_cmd docker
need_cmd kind
need_cmd kubectl
need_cmd tar

mkdir -p "${OUT_DIR}"

run_capture() {
  local name=$1
  shift
  {
    echo "$ $*"
    "$@"
  } > "${OUT_DIR}/${name}.txt" 2>&1 || true
}

run_capture kind-clusters kind get clusters
run_capture docker-containers docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

{
  echo "$ docker ps --format '{{.Names}}' | grep -E '${CLUSTER_PATTERN}'"
  docker ps --format '{{.Names}}' | grep -E "${CLUSTER_PATTERN}" | sort || true
  echo
  echo "$ docker ps --format '{{.Names}}' | grep -E '${CLUSTER_PATTERN}' | wc -l"
  docker ps --format '{{.Names}}' | grep -E "${CLUSTER_PATTERN}" | wc -l
} > "${OUT_DIR}/container-count.txt" 2>&1

{
  echo "$ inspect node memory limits"
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    echo "${node} $(docker inspect -f '{{.HostConfig.Memory}}' "${node}")"
  done < <(docker ps --format '{{.Names}}' | grep -E "${CLUSTER_PATTERN}" | sort || true)
} > "${OUT_DIR}/node-memory.txt" 2>&1

if [[ -f "${HOST_KUBECONFIG}" ]]; then
  run_capture host-nodes kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-host get nodes -o wide
  run_capture host-pods kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-host get pods -A -o wide
  run_capture karmada-clusters kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get clusters.cluster.karmada.io -o wide
  run_capture karmada-api-resources bash -lc "kubectl --kubeconfig '${HOST_KUBECONFIG}' --context karmada-apiserver api-resources | grep -E 'cluster.karmada.io|policy.karmada.io|work.karmada.io|search.karmada.io'"
  run_capture karmada-apiservices bash -lc "kubectl --kubeconfig '${HOST_KUBECONFIG}' --context karmada-apiserver get apiservices | grep -E 'karmada.io|metrics.k8s.io'"
fi

if [[ -f "${MEMBERS_KUBECONFIG}" ]]; then
  run_capture member1-nodes kubectl --kubeconfig "${MEMBERS_KUBECONFIG}" --context member1 get nodes -o wide
  run_capture member2-nodes kubectl --kubeconfig "${MEMBERS_KUBECONFIG}" --context member2 get nodes -o wide
fi

run_capture status-summary "${ROOT_DIR}/scripts/status.sh"

(
  cd "${ARTIFACTS_DIR}"
  tar -czf "karmada-kind-proof-${STAMP}.tar.gz" "${STAMP}"
)

rm -f "${LATEST_LINK}"
ln -s "${OUT_DIR}" "${LATEST_LINK}"

cat <<EOF
Saved proof artifacts to:
- ${OUT_DIR}
- ${ARTIFACTS_DIR}/karmada-kind-proof-${STAMP}.tar.gz
- ${LATEST_LINK}
EOF
