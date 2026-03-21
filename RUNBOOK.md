# Runbook: Karmada on kind (3 clusters, 12 containers)

**Status:** DRAFT — Pending independent validation by team members
**Last Updated:** 2026-03-20
**Source:** Initial reproducibility setup for Parth's Karmada-on-kind task

---

## Purpose

Provision a reproducible local Karmada environment using kind with:
- 3 clusters total
- 12 kind node containers total
- 1 GB memory limit per kind node container
- 1 host cluster running the Karmada control plane
- 2 member clusters joined to Karmada

This runbook uses the top-level reproducibility scripts in `karmada-kind/` and the upstream `karmada/` clone for control-plane deployment logic.

---

## Prerequisites

### Host Machine
- macOS or Linux with Docker available
- Enough free RAM and CPU to run 12 kind node containers plus Karmada control-plane workloads
- Working internet access for image pulls and Go module resolution if caches are cold

### Required Tools

| Tool | Verification Command |
|------|----------------------|
| Docker | `docker version` |
| kind | `kind version` |
| kubectl | `kubectl version --client` |
| Go | `go version` |
| make | `make --version` |

**STOP CONDITION:** If any required tool is missing, STOP and install it before proceeding.

### Required Repository Layout

From the parent directory of this runbook:

| Path | Purpose | Verification Command |
|------|---------|----------------------|
| `./karmada/` | Upstream cloned Karmada repo | `test -d ./karmada/.git && echo ok` |
| `./scripts/bootstrap-karmada.sh` | Main setup script | `test -x ./scripts/bootstrap-karmada.sh && echo ok` |
| `./scripts/cleanup.sh` | Cleanup script | `test -x ./scripts/cleanup.sh && echo ok` |
| `./configs/kind/host-4nodes.yaml` | Host kind topology | `test -f ./configs/kind/host-4nodes.yaml && echo ok` |
| `./configs/kind/member1-4nodes.yaml` | Member 1 topology | `test -f ./configs/kind/member1-4nodes.yaml && echo ok` |
| `./configs/kind/member2-4nodes.yaml` | Member 2 topology | `test -f ./configs/kind/member2-4nodes.yaml && echo ok` |

**STOP CONDITION:** If `./karmada/` is missing or the scripts/configs are missing, STOP and fix the repo layout.

---

## Topology

### Cluster Layout

| Cluster | Role | Nodes | Expected kind containers |
|---------|------|-------|--------------------------|
| `karmada-host` | Host/control plane | 4 | 4 |
| `member1` | Member cluster | 4 | 4 |
| `member2` | Member cluster | 4 | 4 |

### Total

- **3 clusters**
- **12 kind node containers**
- **1 GB memory limit per kind node container**

**IMPORTANT:** This runbook defines “12 containers” as **12 kind node containers** (4 per cluster), not the number of Kubernetes pods or internal runtime containers inside each node.

---

## Working Directory

```bash
cd /Users/pamehta/karmada-kind
```

**ASSUMPTION:** All commands below assume this working directory.

---

## Cleanup Existing State

Before creating a fresh environment, remove prior kind clusters for this project:

```bash
./scripts/cleanup.sh
```

### Expected Output
- Existing clusters `karmada-host`, `member1`, and `member2` are deleted if present
- `kind get clusters` shows no leftover project clusters

**STOP CONDITION:** If cleanup fails or old clusters remain, STOP and inspect Docker/kind state before continuing.

---

## Bootstrap Command

```bash
./scripts/bootstrap-karmada.sh
```

### What this script does

1. Creates 3 kind clusters:
   - `karmada-host`
   - `member1`
   - `member2`
2. Creates 4 nodes per cluster using the checked-in kind configs
3. Applies a Docker memory limit of `1g` per kind node container
4. Builds Karmada images from source by default
5. Loads Karmada control-plane images into `karmada-host`
6. Deploys the Karmada control plane on `karmada-host`
7. Joins `member1` and `member2` to the Karmada API server
8. Deploys scheduler estimators and metrics-server to both members

### Environment Variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `CLUSTER_VERSION` | `kindest/node:v1.35.0` | kind node image |
| `NODE_MEMORY_LIMIT` | `1g` | Docker memory limit per kind node container |
| `BUILD_IMAGES` | `true` | Build Karmada images from source before loading |
| `KARMADA_APISERVER_VERSION` | `v1.35.0` | Karmada apiserver version injected into deploy manifest |
| `HOST_IPADDRESS` | auto-detected | Host-reachable IP used for kind API server binding on macOS/Linux |

Example override:

```bash
HOST_IPADDRESS=192.168.1.124 NODE_MEMORY_LIMIT=1g BUILD_IMAGES=true ./scripts/bootstrap-karmada.sh
```

**STOP CONDITION:** If the script exits non-zero, STOP and inspect the printed failure point before retrying.

---

## Verification Steps

### 1. Verify all kind clusters exist
```bash
kind get clusters
```

Expected:
- `karmada-host`
- `member1`
- `member2`

**STOP CONDITION:** If any expected cluster is missing, STOP.

### 2. Verify there are 12 kind node containers
```bash
docker ps --format '{{.Names}}' | grep -E '^(karmada-host|member1|member2)-(control-plane|worker)' | wc -l
```

Expected:
- `12`

**STOP CONDITION:** If the count is not 12, STOP and inspect cluster creation.

### 3. Verify node memory limits
```bash
for n in $(docker ps --format '{{.Names}}' | grep -E '^(karmada-host|member1|member2)-(control-plane|worker)'); do
  echo "$n $(docker inspect -f '{{.HostConfig.Memory}}' "$n")"
done
```

Expected:
- Each node shows approximately `1073741824` bytes (`1 GiB`)

**STOP CONDITION:** If any node is not limited to ~1 GiB, STOP and investigate Docker update behavior.

### 4. Verify host cluster nodes
```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-host get nodes
```

Expected:
- 4 Ready nodes in `karmada-host`

### 5. Verify member cluster nodes
```bash
kubectl --kubeconfig ./.state/kubeconfig/members.config --context member1 get nodes
kubectl --kubeconfig ./.state/kubeconfig/members.config --context member2 get nodes
```

Expected:
- 4 Ready nodes in `member1`
- 4 Ready nodes in `member2`

**STOP CONDITION:** If any node is NotReady, STOP and inspect cluster health.

### 6. Verify Karmada control-plane pods
```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-host get pods -n karmada-system
```

Expected:
- Control-plane pods present and mostly `Running`
- Scheduler estimator pods may also appear after member join

**STOP CONDITION:** If control-plane pods are CrashLoopBackOff or Pending indefinitely, STOP.

### 7. Verify member registration in Karmada
```bash
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-apiserver get clusters.cluster.karmada.io
```

Expected:
- `member1`
- `member2`

**STOP CONDITION:** If either member cluster is missing or not Ready, STOP and inspect join failures.

---

## Quick Status Command

```bash
./scripts/status.sh
```

This prints:
- current kind clusters
- related Docker node containers
- host-cluster pods
- Karmada registered clusters
- member cluster nodes

---

## Findings Template

Record findings after each successful or failed run:

### Environment
- Host machine:
- Docker version:
- kind version:
- kubectl version:
- Go version:

### Outcome
- Bootstrap succeeded: yes/no
- Total clusters observed:
- Total kind node containers observed:
- Memory limit per node verified: yes/no

### Karmada Health
- Host control plane healthy: yes/no
- `member1` joined: yes/no
- `member2` joined: yes/no

### Notes
- Build time:
- Any failures encountered:
- Any manual intervention required:
- Resource pressure observations:

---

## Stop Conditions Summary

| Condition | Action |
|-----------|--------|
| Missing Docker/kind/kubectl/go/make | STOP — Prerequisites not satisfied |
| `./karmada/` clone missing | STOP — Upstream dependency absent |
| Cleanup leaves stale clusters | STOP — Resolve leftover kind state |
| Fewer than 3 clusters created | STOP — Bootstrap incomplete |
| Fewer or more than 12 kind node containers | STOP — Topology mismatch |
| Any node missing 1 GiB memory limit | STOP — Resource limit mismatch |
| Karmada control-plane pods unhealthy | STOP — Investigate deployment |
| `member1` or `member2` not registered | STOP — Investigate join workflow |

---

## Critical Warnings

### The stock upstream script does not match this requirement

The upstream script `karmada/hack/local-up-karmada.sh` creates **4 clusters**, not 3:
- `karmada-host`
- `member1`
- `member2`
- `member3`

Do **not** use that script when the requirement is specifically **3 clusters**.

### “12 containers” means kind node containers here

This runbook treats the requirement as:
- 3 clusters × 4 kind nodes each = 12 Docker containers

If your advisor/team meant something else by “12containers,” update the runbook before claiming reproducibility.

### Docker memory limits are applied after cluster creation

kind itself does not directly expose per-node Docker memory settings in the checked-in config files used here. This workflow applies limits with `docker update` after the node containers exist.

If Docker Desktop or your host ignores or alters these limits, results may differ.

---

## Notes

- Kubeconfigs are written under `./.state/kubeconfig/`
- The outer `karmada-kind/` directory is the reproducibility project
- The nested `karmada/` clone remains the upstream source dependency
- This runbook is still draft status until a full end-to-end bootstrap is independently validated

---

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-03-20 | Initial draft created for 3-cluster reproducible Karmada-on-kind setup | Ryzen |

---

**END OF DOCUMENT**
tstrap is independently validated

---

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-03-20 | Initial draft created for 3-cluster reproducible Karmada-on-kind setup | Ryzen |

---

**END OF DOCUMENT**
is still draft status until a full end-to-end bootstrap is independently validated

---

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-03-20 | Initial draft created for 3-cluster reproducible Karmada-on-kind setup | Ryzen |

---

**END OF DOCUMENT**
