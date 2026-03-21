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

CLUSTER_VERSION="${CLUSTER_VERSION:-kindest/node:v1.35.0}"
NODE_MEMORY_LIMIT="${NODE_MEMORY_LIMIT:-1g}"
BUILD_IMAGES="${BUILD_IMAGES:-true}"
KARMADA_APISERVER_VERSION="${KARMADA_APISERVER_VERSION:-v1.35.0}"
HOST_IPADDRESS="${HOST_IPADDRESS:-}"

HOST_CLUSTER_NAME="karmada-host"
MEMBER1_CLUSTER_NAME="member1"
MEMBER2_CLUSTER_NAME="member2"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd kind
need_cmd kubectl
need_cmd docker
need_cmd go
need_cmd make

if [[ ! -d "${KARMADA_REPO}/.git" ]]; then
  echo "Expected nested karmada clone at ${KARMADA_REPO}" >&2
  exit 1
fi

if [[ -z "${HOST_IPADDRESS}" ]]; then
  case "$(uname -s)" in
    Darwin)
      HOST_IPADDRESS=$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
except Exception:
    pass
finally:
    s.close()
PY
)
      ;;
    Linux)
      HOST_IPADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
      if [[ -z "${HOST_IPADDRESS}" ]]; then
        HOST_IPADDRESS=$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(('8.8.8.8', 80))
    print(s.getsockname()[0])
except Exception:
    pass
finally:
    s.close()
PY
)
      fi
      ;;
  esac
fi

if [[ -z "${HOST_IPADDRESS}" ]]; then
  echo "Unable to determine a host-reachable IP address. Set HOST_IPADDRESS explicitly." >&2
  exit 1
fi

echo "Using host API server address: ${HOST_IPADDRESS}"

mkdir -p "${KUBECONFIG_DIR}"
rm -f "${HOST_KUBECONFIG}" "${MEMBER1_KUBECONFIG}" "${MEMBER2_KUBECONFIG}" "${MEMBERS_KUBECONFIG}"
TMP_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_CONFIG_DIR}"' EXIT

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
  local rendered_config=$4

  if kind get clusters 2>/dev/null | grep -qx "${name}"; then
    echo "Cluster already exists, deleting first: ${name}"
    kind delete cluster --name "${name}"
  fi

  render_kind_config "${config}" "${rendered_config}"

  echo "Creating cluster ${name}"
  kind create cluster \
    --name "${name}" \
    --image "${CLUSTER_VERSION}" \
    --kubeconfig "${kubeconfig}" \
    --config "${rendered_config}"

  kubectl config rename-context "kind-${name}" "${name}" --kubeconfig "${kubeconfig}"
}

apply_memory_limit() {
  local cluster=$1
  local nodes
  nodes=$(docker ps -a --format '{{.Names}}' | grep -E "^${cluster}-(control-plane|worker|worker2|worker3|worker4|worker5|worker6|worker7|worker8|worker9)$" || true)
  if [[ -z "${nodes}" ]]; then
    return
  fi
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    echo "Applying memory limit ${NODE_MEMORY_LIMIT} to ${node}"
    docker update --memory "${NODE_MEMORY_LIMIT}" --memory-swap "${NODE_MEMORY_LIMIT}" "${node}" >/dev/null
  done <<< "${nodes}"
}

merge_member_kubeconfigs() {
  export KUBECONFIG="${MEMBER1_KUBECONFIG}:${MEMBER2_KUBECONFIG}"
  kubectl config view --flatten > "${MEMBERS_KUBECONFIG}"
  unset KUBECONFIG
}

build_and_load_images() {
  local image_tag
  image_tag=$(git -C "${KARMADA_REPO}" describe --tags --always --dirty 2>/dev/null || echo latest)

  if [[ "${BUILD_IMAGES}" == "true" ]]; then
    echo "Building Karmada images from source"
    make images GOOS=linux --directory="${KARMADA_REPO}"
  else
    echo "Skipping image build from source"
  fi

  local host_images=(
    "docker.io/karmada/karmada-controller-manager:${image_tag}"
    "docker.io/karmada/karmada-scheduler:${image_tag}"
    "docker.io/karmada/karmada-descheduler:${image_tag}"
    "docker.io/karmada/karmada-webhook:${image_tag}"
    "docker.io/karmada/karmada-scheduler-estimator:${image_tag}"
    "docker.io/karmada/karmada-aggregated-apiserver:${image_tag}"
    "docker.io/karmada/karmada-search:${image_tag}"
    "docker.io/karmada/karmada-metrics-adapter:${image_tag}"
  )

  for image in "${host_images[@]}"; do
    echo "Loading ${image} into ${HOST_CLUSTER_NAME}"
    kind load docker-image "${image}" --name "${HOST_CLUSTER_NAME}"
    docker tag "${image}" "${image%:*}:latest"
    kind load docker-image "${image%:*}:latest" --name "${HOST_CLUSTER_NAME}"
  done
}

create_cluster "${HOST_CLUSTER_NAME}" "${HOST_KUBECONFIG}" "${ROOT_DIR}/configs/kind/host-4nodes.yaml" "${TMP_CONFIG_DIR}/host.yaml"
create_cluster "${MEMBER1_CLUSTER_NAME}" "${MEMBER1_KUBECONFIG}" "${ROOT_DIR}/configs/kind/member1-4nodes.yaml" "${TMP_CONFIG_DIR}/member1.yaml"
create_cluster "${MEMBER2_CLUSTER_NAME}" "${MEMBER2_KUBECONFIG}" "${ROOT_DIR}/configs/kind/member2-4nodes.yaml" "${TMP_CONFIG_DIR}/member2.yaml"

apply_memory_limit "${HOST_CLUSTER_NAME}"
apply_memory_limit "${MEMBER1_CLUSTER_NAME}"
apply_memory_limit "${MEMBER2_CLUSTER_NAME}"

merge_member_kubeconfigs
build_and_load_images

pushd "${KARMADA_REPO}" >/dev/null
export KUBECONFIG_PATH="${KUBECONFIG_DIR}"
export MAIN_KUBECONFIG="${HOST_KUBECONFIG}"
export MEMBER_CLUSTER_KUBECONFIG="${MEMBERS_KUBECONFIG}"
export HOST_CLUSTER_NAME="${HOST_CLUSTER_NAME}"
export MEMBER_CLUSTER_1_NAME="${MEMBER1_CLUSTER_NAME}"
export MEMBER_CLUSTER_2_NAME="${MEMBER2_CLUSTER_NAME}"
export KARMADA_APISERVER_VERSION

./hack/deploy-karmada.sh "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}"

go install github.com/karmada-io/karmada/cmd/karmadactl
KARMADACTL_BIN="$(go env GOPATH | awk -F: '{print $1}')/bin/karmadactl"
export KUBECONFIG="${HOST_KUBECONFIG}"

"${KARMADACTL_BIN}" join --karmada-context="karmada-apiserver" "${MEMBER1_CLUSTER_NAME}" --cluster-kubeconfig="${MEMBERS_KUBECONFIG}" --cluster-context="${MEMBER1_CLUSTER_NAME}"
./hack/deploy-scheduler-estimator.sh "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MEMBERS_KUBECONFIG}" "${MEMBER1_CLUSTER_NAME}"
./hack/deploy-k8s-metrics-server.sh "${MEMBERS_KUBECONFIG}" "${MEMBER1_CLUSTER_NAME}"

"${KARMADACTL_BIN}" join --karmada-context="karmada-apiserver" "${MEMBER2_CLUSTER_NAME}" --cluster-kubeconfig="${MEMBERS_KUBECONFIG}" --cluster-context="${MEMBER2_CLUSTER_NAME}"
./hack/deploy-scheduler-estimator.sh "${HOST_KUBECONFIG}" "${HOST_CLUSTER_NAME}" "${MEMBERS_KUBECONFIG}" "${MEMBER2_CLUSTER_NAME}"
./hack/deploy-k8s-metrics-server.sh "${MEMBERS_KUBECONFIG}" "${MEMBER2_CLUSTER_NAME}"

unset KUBECONFIG
popd >/dev/null

echo
echo "Bootstrap complete."
echo "Host kubeconfig:    ${HOST_KUBECONFIG}"
echo "Members kubeconfig: ${MEMBERS_KUBECONFIG}"
echo
echo "Try:"
echo "  ${ROOT_DIR}/scripts/status.sh"
