#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KARMADA_REPO="${ROOT_DIR}/karmada"
STATE_DIR="${ROOT_DIR}/.state"
KUBECONFIG_DIR="${STATE_DIR}/kubeconfig"
HOST_KUBECONFIG="${KUBECONFIG_DIR}/karmada.config"
MEMBER1_KUBECONFIG="${KUBECONFIG_DIR}/member1.config"
MEMBER2_KUBECONFIG="${KUBECONFIG_DIR}/member2.config"
MEMBERS_KUBECONFIG="${KUBECONFIG_DIR}/members.config"
LOG_DIR="${STATE_DIR}/logs"

HOST_CLUSTER_NAME="karmada-host"
MEMBER1_CLUSTER_NAME="member1"
MEMBER2_CLUSTER_NAME="member2"
PROJECT_CLUSTERS=("${HOST_CLUSTER_NAME}" "${MEMBER1_CLUSTER_NAME}" "${MEMBER2_CLUSTER_NAME}")
CLUSTER_PATTERN='^(karmada-host|member1|member2)-(control-plane|worker|worker2|worker3)$'

CLUSTER_VERSION="${CLUSTER_VERSION:-kindest/node:v1.35.0}"
NODE_MEMORY_LIMIT="${NODE_MEMORY_LIMIT:-1g}"
BUILD_IMAGES="${BUILD_IMAGES:-true}"
KARMADA_APISERVER_VERSION="${KARMADA_APISERVER_VERSION:-v1.35.0}"
KARMADA_REPO_URL="${KARMADA_REPO_URL:-https://github.com/karmada-io/karmada.git}"
KARMADA_REF="${KARMADA_REF:-3424bc71d1bd6662b7bf7d5ed7510f075d5eff9f}"
HOST_IPADDRESS="${HOST_IPADDRESS:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd kind
need_cmd kubectl
need_cmd docker
need_cmd go
need_cmd git
need_cmd make
need_cmd python3
need_cmd grep
need_cmd awk
need_cmd sed

warn() {
  echo "WARN: $*" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_karmada_repo() {
  KARMADA_REPO_URL="${KARMADA_REPO_URL}" KARMADA_REF="${KARMADA_REF}" \
    "${ROOT_DIR}/scripts/ensure-karmada-repo.sh"
}

preflight_checks() {
  if kind get clusters 2>/dev/null | grep -Eq '^(karmada-host|member1|member2)$'; then
    warn "Existing project kind clusters detected. A clean rebuild will delete and recreate them."
  fi

  if [[ -f "${HOME}/.kube/config" ]]; then
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || true)
    if [[ -n "${current_context}" ]] && [[ "${current_context}" != kind-* ]] && [[ "${current_context}" != "karmada-host" ]] && [[ "${current_context}" != "karmada-apiserver" ]] && [[ "${current_context}" != "member1" ]] && [[ "${current_context}" != "member2" ]]; then
      warn "Your default kubectl context is '${current_context}'. This project writes dedicated kubeconfigs under ${KUBECONFIG_DIR}; use those explicitly after bootstrap."
    fi
  fi

  if [[ "${BUILD_IMAGES}" != "true" ]]; then
    warn "BUILD_IMAGES=${BUILD_IMAGES}; bootstrap will rely on whatever Karmada images already exist locally or remotely."
  fi
}

resolve_host_ip() {
  if [[ -n "${HOST_IPADDRESS}" ]]; then
    return 0
  fi

  HOST_IPADDRESS=$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("8.8.8.8", 80))
    print(s.getsockname()[0])
except Exception:
    pass
finally:
    s.close()
PY
)

  if [[ -z "${HOST_IPADDRESS}" ]]; then
    echo "Unable to determine HOST_IPADDRESS automatically. Set HOST_IPADDRESS explicitly." >&2
    exit 1
  fi
}

render_kind_config() {
  local src=$1
  local dst=$2
  awk -v host_ip="${HOST_IPADDRESS}" '
    /^networking:/ {
      print $0
      print "  apiServerAddress: \"" host_ip "\""
      next
    }
    { print $0 }
  ' "${src}" > "${dst}"
}

create_cluster() {
  local name=$1
  local kubeconfig=$2
  local config=$3
  local rendered=$4

  if kind get clusters 2>/dev/null | grep -qx "${name}"; then
    echo "Deleting existing cluster before rebuild: ${name}"
    kind delete cluster --name "${name}"
  fi

  render_kind_config "${config}" "${rendered}"

  echo "Creating kind cluster: ${name}"
  kind create cluster \
    --name "${name}" \
    --image "${CLUSTER_VERSION}" \
    --config "${rendered}" \
    --kubeconfig "${kubeconfig}"

  kubectl config rename-context "kind-${name}" "${name}" --kubeconfig "${kubeconfig}" >/dev/null
}

wait_for_nodes_ready() {
  local kubeconfig=$1
  local context=$2
  echo "Waiting for nodes in ${context} to become Ready"
  kubectl --kubeconfig "${kubeconfig}" --context "${context}" wait --for=condition=Ready nodes --all --timeout=300s
}

apply_memory_limit() {
  local cluster=$1
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    echo "Applying memory limit ${NODE_MEMORY_LIMIT} to ${node}"
    docker update --memory "${NODE_MEMORY_LIMIT}" --memory-swap "${NODE_MEMORY_LIMIT}" "${node}" >/dev/null
  done < <(docker ps -a --format '{{.Names}}' | grep -E "^${cluster}-(control-plane|worker|worker2|worker3)$" | sort || true)
}

verify_container_count() {
  local count
  count=$(docker ps --format '{{.Names}}' | grep -E "${CLUSTER_PATTERN}" | wc -l | tr -d ' ')
  echo "Observed project kind node containers: ${count}"
  if [[ "${count}" != "12" ]]; then
    echo "Expected 12 kind node containers, got ${count}" >&2
    exit 1
  fi
}

merge_member_kubeconfigs() {
  export KUBECONFIG="${MEMBER1_KUBECONFIG}:${MEMBER2_KUBECONFIG}"
  kubectl config view --flatten > "${MEMBERS_KUBECONFIG}"
  unset KUBECONFIG
}

build_and_load_images() {
  if [[ "${BUILD_IMAGES}" != "true" ]]; then
    echo "Skipping image build because BUILD_IMAGES=${BUILD_IMAGES}"
    return 0
  fi

  local registry="docker.io/karmada"
  local version="latest"

  echo "Building Karmada images from source"
  (
    cd "${KARMADA_REPO}"
    export VERSION="${version}"
    export REGISTRY="${registry}"
    make images GOOS=linux
  )

  local host_images=(
    "${registry}/karmada-controller-manager:${version}"
    "${registry}/karmada-scheduler:${version}"
    "${registry}/karmada-descheduler:${version}"
    "${registry}/karmada-webhook:${version}"
    "${registry}/karmada-scheduler-estimator:${version}"
    "${registry}/karmada-aggregated-apiserver:${version}"
    "${registry}/karmada-search:${version}"
    "${registry}/karmada-metrics-adapter:${version}"
  )

  for image in "${host_images[@]}"; do
    echo "Loading ${image} into ${HOST_CLUSTER_NAME}"
    kind load docker-image "${image}" --name "${HOST_CLUSTER_NAME}"
  done
}

wait_for_karmada_cluster_ready() {
  local cluster_name=$1
  echo "Waiting for Karmada registered cluster '${cluster_name}' to become Ready"
  for _ in {1..60}; do
    local ready
    ready=$(kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get clusters.cluster.karmada.io "${cluster_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "${ready}" == "True" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

verify_karmada_api() {
  echo "Verifying Karmada API registration"

  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get --raw /readyz >/dev/null

  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver api-resources | grep -q '^clusters[[:space:]].*cluster.karmada.io/' \
    || fail "Karmada cluster API was not registered"

  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver api-resources | grep -q '^propagationpolicies[[:space:]].*policy.karmada.io/' \
    || fail "PropagationPolicy CRD is missing from the Karmada API"

  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-apiserver get apiservice v1alpha1.cluster.karmada.io >/dev/null \
    || fail "APIService v1alpha1.cluster.karmada.io is missing"
}

verify_post_bootstrap() {
  echo "Running post-bootstrap verification"
  verify_container_count
  verify_karmada_api

  kubectl --kubeconfig "${HOST_KUBECONFIG}" --context karmada-host get pods -n karmada-system >/dev/null
  kubectl --kubeconfig "${MEMBERS_KUBECONFIG}" --context member1 get nodes >/dev/null
  kubectl --kubeconfig "${MEMBERS_KUBECONFIG}" --context member2 get nodes >/dev/null

  wait_for_karmada_cluster_ready "${MEMBER1_CLUSTER_NAME}" || fail "member1 did not become Ready in Karmada"
  wait_for_karmada_cluster_ready "${MEMBER2_CLUSTER_NAME}" || fail "member2 did not become Ready in Karmada"
}

deploy_karmada() {
  echo "Deploying Karmada control plane"
  (
    cd "${KARMADA_REPO}"
    export KUBECONFIG_PATH="${KUBECONFIG_DIR}"
    export MAIN_KUBECONFIG="${HOST_KUBECONFIG}"
    export MEMBER_CLUSTER_KUBECONFIG="${MEMBERS_KUBECONFIG}"
    export HOST_CLUSTER_NAME="${HOST_CLUSTER_NAME}"
    export MEMBER_CLUSTER_1_NAME="${MEMBER1_CLUSTER_NAME}"
    export MEMBER_CLUSTER_2_NAME="${MEMBER2_CLUSTER_NAME}"
    export KARMADA_APISERVER_VERSION

    local deploy_attempt
    for deploy_attempt in 1 2 3; do
      if ./hack/deploy-karmada.sh "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}"; then
        break
      fi
      if [[ "${deploy_attempt}" -eq 3 ]]; then
        fail "Karmada deploy failed after ${deploy_attempt} attempts"
      fi
      warn "Karmada deploy attempt ${deploy_attempt} failed; waiting for control-plane pods to settle before retrying..."
      sleep 20
    done

    local karmadactl_bin="${STATE_DIR}/bin/karmadactl"
    mkdir -p "${STATE_DIR}/bin"
    GO111MODULE=on go build -o "${karmadactl_bin}" ./cmd/karmadactl

    export KUBECONFIG="${HOST_KUBECONFIG}"

    "${karmadactl_bin}" join --karmada-context="karmada-apiserver" "${MEMBER1_CLUSTER_NAME}" --cluster-kubeconfig="${MEMBERS_KUBECONFIG}" --cluster-context="${MEMBER1_CLUSTER_NAME}"
    ./hack/deploy-scheduler-estimator.sh "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MEMBERS_KUBECONFIG}" "${MEMBER1_CLUSTER_NAME}"
    ./hack/deploy-k8s-metrics-server.sh "${MEMBERS_KUBECONFIG}" "${MEMBER1_CLUSTER_NAME}"

    "${karmadactl_bin}" join --karmada-context="karmada-apiserver" "${MEMBER2_CLUSTER_NAME}" --cluster-kubeconfig="${MEMBERS_KUBECONFIG}" --cluster-context="${MEMBER2_CLUSTER_NAME}"
    ./hack/deploy-scheduler-estimator.sh "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MEMBERS_KUBECONFIG}" "${MEMBER2_CLUSTER_NAME}"
    ./hack/deploy-k8s-metrics-server.sh "${MEMBERS_KUBECONFIG}" "${MEMBER2_CLUSTER_NAME}"

    unset KUBECONFIG
  )
}

mkdir -p "${KUBECONFIG_DIR}" "${LOG_DIR}"
rm -f "${HOST_KUBECONFIG}" "${MEMBER1_KUBECONFIG}" "${MEMBER2_KUBECONFIG}" "${MEMBERS_KUBECONFIG}"
TMP_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_CONFIG_DIR}"' EXIT

preflight_checks
ensure_karmada_repo
resolve_host_ip

echo "Using host API server address: ${HOST_IPADDRESS}"
echo "Target topology: 3 clusters / 12 kind node containers / ${NODE_MEMORY_LIMIT} per node"
echo "Using upstream Karmada source:"
echo "- url: ${KARMADA_REPO_URL}"
echo "- ref: ${KARMADA_REF}"

create_cluster "${HOST_CLUSTER_NAME}" "${HOST_KUBECONFIG}" "${ROOT_DIR}/configs/kind/host-4nodes.yaml" "${TMP_CONFIG_DIR}/host.yaml"
create_cluster "${MEMBER1_CLUSTER_NAME}" "${MEMBER1_KUBECONFIG}" "${ROOT_DIR}/configs/kind/member1-4nodes.yaml" "${TMP_CONFIG_DIR}/member1.yaml"
create_cluster "${MEMBER2_CLUSTER_NAME}" "${MEMBER2_KUBECONFIG}" "${ROOT_DIR}/configs/kind/member2-4nodes.yaml" "${TMP_CONFIG_DIR}/member2.yaml"

wait_for_nodes_ready "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}"
wait_for_nodes_ready "${MEMBER1_KUBECONFIG}" "${MEMBER1_CLUSTER_NAME}"
wait_for_nodes_ready "${MEMBER2_KUBECONFIG}" "${MEMBER2_CLUSTER_NAME}"

apply_memory_limit "${HOST_CLUSTER_NAME}"
apply_memory_limit "${MEMBER1_CLUSTER_NAME}"
apply_memory_limit "${MEMBER2_CLUSTER_NAME}"
verify_container_count
merge_member_kubeconfigs
build_and_load_images
deploy_karmada
verify_post_bootstrap

cat <<EOF

Bootstrap complete.

Generated kubeconfigs:
- ${HOST_KUBECONFIG}
- ${MEMBERS_KUBECONFIG}

Context guide:
- host Kubernetes cluster:   kubectl --kubeconfig ${HOST_KUBECONFIG} --context karmada-host ...
- Karmada API server:        kubectl --kubeconfig ${HOST_KUBECONFIG} --context karmada-apiserver ...
- member clusters:           kubectl --kubeconfig ${MEMBERS_KUBECONFIG} --context member1|member2 ...

Important:
- Use --context karmada-host for host-cluster resources like nodes/pods/services.
- Use --context karmada-apiserver for Karmada CRDs like clusters.cluster.karmada.io,
  propagationpolicies.policy.karmada.io, and search.karmada.io resources.

Next steps:
  ${ROOT_DIR}/scripts/status.sh
  ${ROOT_DIR}/scripts/capture-artifacts.sh
EOF
