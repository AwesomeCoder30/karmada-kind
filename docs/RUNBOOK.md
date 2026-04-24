# Runbook: Karmada on kind

This runbook documents how to reproduce a local Karmada lab with:

- `3` kind clusters
- `12` kind node containers total
- `1 GiB` memory per kind node container
- Karmada control plane on `karmada-host`
- two member clusters: `member1` and `member2`

## 1. Clone and enter the repo

```bash
git clone <your-repo-url>
cd karmada-kind
```

## 2. Verify prerequisites

```bash
docker version
kind version
kubectl version --client
git --version
go version
make --version
python3 --version
```

Stop if any required tool is missing.

## 3. Verify expected checked-in files

```bash
test -x ./scripts/bootstrap-karmada.sh && echo ok
test -x ./scripts/ensure-karmada-repo.sh && echo ok
test -x ./scripts/cleanup.sh && echo ok
test -x ./scripts/status.sh && echo ok
test -x ./scripts/capture-artifacts.sh && echo ok
test -f ./configs/kind/host-4nodes.yaml && echo ok
test -f ./configs/kind/member1-4nodes.yaml && echo ok
test -f ./configs/kind/member2-4nodes.yaml && echo ok
test -f ./docs/RUNBOOK.md && echo ok
test -f ./examples/manifests/hello-world.yaml && echo ok
```

## 4. Clean previous state

```bash
./scripts/cleanup.sh
```

Optional:

```bash
CLEAN_KARMADA_SOURCE=true ./scripts/cleanup.sh
```

## 5. Bootstrap the environment

```bash
./scripts/bootstrap-karmada.sh
```

Optional overrides:

```bash
HOST_IPADDRESS=192.168.1.124 \
NODE_MEMORY_LIMIT=1g \
BUILD_IMAGES=true \
KARMADA_REF=3424bc71d1bd6662b7bf7d5ed7510f075d5eff9f \
./scripts/bootstrap-karmada.sh
```

## 6. What bootstrap does

1. fetches upstream Karmada source if missing
2. pins the local checkout to the configured upstream ref
3. creates `karmada-host`, `member1`, and `member2`
4. provisions four kind nodes per cluster
5. applies the Docker memory cap to each kind node container
6. writes dedicated kubeconfigs under `./.state/kubeconfig/`
7. builds Karmada images from source
8. deploys the Karmada control plane on `karmada-host`
9. joins `member1` and `member2`
10. runs post-bootstrap verification

## 7. Verification

### 7.1 Verify kind clusters exist

```bash
kind get clusters
```

Expected:

- `karmada-host`
- `member1`
- `member2`

### 7.2 Verify the node container count

```bash
docker ps --format '{{.Names}}' | grep -E '^(karmada-host|member1|member2)-(control-plane|worker|worker2|worker3)$' | wc -l
```

Expected:

- `12`

### 7.3 Verify the memory limit

```bash
for n in $(docker ps --format '{{.Names}}' | grep -E '^(karmada-host|member1|member2)-(control-plane|worker|worker2|worker3)$'); do
  echo "$n $(docker inspect -f '{{.HostConfig.Memory}}' "$n")"
done
```

Expected:

- around `1073741824` for each project node container

### 7.4 Verify host cluster nodes

```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-host get nodes
```

Expected:

- four Ready nodes

### 7.5 Verify member cluster nodes

```bash
kubectl --kubeconfig ./.state/kubeconfig/members.config --context member1 get nodes
kubectl --kubeconfig ./.state/kubeconfig/members.config --context member2 get nodes
```

### 7.6 Verify Karmada system pods

```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-host get pods -n karmada-system
```

### 7.7 Verify registered Karmada member clusters

```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-apiserver get clusters.cluster.karmada.io
```

Expected:

- `member1`
- `member2`
- `READY=True`

### 7.8 Verify Karmada APIs

```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-apiserver api-resources | grep -E 'cluster.karmada.io|policy.karmada.io|work.karmada.io|search.karmada.io'
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-apiserver get apiservices | grep -E 'karmada.io|metrics.k8s.io'
```

## 8. Context discipline

Use explicit kubeconfigs and contexts:

- `karmada-host` for host-cluster Kubernetes resources
- `karmada-apiserver` for Karmada CRDs and policies
- `member1` and `member2` to inspect propagated workloads

Do not rely on an unrelated default `kubectl` context when validating this lab.

## 9. Capture proof artifacts

```bash
./scripts/capture-artifacts.sh
```

Expected outputs:

- `./artifacts/<timestamp>/`
- `./artifacts/latest`
- `./artifacts/karmada-kind-proof-<timestamp>.tar.gz`

## 10. Example workload files

- `examples/manifests/hello-world.yaml`
- `examples/manifests/deployment.yaml`
- `examples/manifests/propagation-policy.yaml`
- `examples/manifests/karmada-host.yaml`

Use these as starting points once the control plane and member clusters are healthy.

## 11. Stop conditions

Stop and investigate if any of these occur:

- prerequisite tools are missing
- fewer than three clusters are created
- fewer or more than twelve project node containers exist
- memory limit is not applied
- host or member nodes fail readiness
- Karmada control-plane pods do not stabilize
- `member1` or `member2` do not register with Karmada
