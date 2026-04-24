# karmada-kind

Reproducible local Karmada-on-kind workspace for a constrained lab setup:

- exactly `3` kind clusters
- exactly `12` kind node containers total
- `4` nodes per cluster
- `1 GiB` Docker memory limit per kind node container
- Karmada control plane running on a dedicated host cluster
- `member1` and `member2` joined as member clusters

This repository is a thin wrapper around upstream Karmada. It does not vendor the entire upstream source tree into Git. Instead, the bootstrap flow fetches a pinned upstream Karmada revision automatically.

## Topology

| Cluster | Role | Nodes |
|---|---|---:|
| `karmada-host` | host cluster running the Karmada control plane | 4 |
| `member1` | member cluster | 4 |
| `member2` | member cluster | 4 |

Total: `3 clusters / 12 kind node containers`

## What is in this repo

- `configs/kind/` — checked-in kind cluster configs
- `scripts/bootstrap-karmada.sh` — full environment bootstrap
- `scripts/ensure-karmada-repo.sh` — fetches pinned upstream Karmada source
- `scripts/status.sh` — one-command status summary
- `scripts/capture-artifacts.sh` — writes proof artifacts and tarball
- `scripts/cleanup.sh` — tears down project clusters and generated local state
- `RUNBOOK.md` — detailed step-by-step instructions
- `deployment.yaml`, `hello-world.yaml`, `propagation-policy.yaml` — example workload and propagation manifests

## Reproducibility model

Bootstrap will automatically:

1. fetch upstream Karmada from `https://github.com/karmada-io/karmada.git`
2. pin the local checkout to commit `3424bc71d1bd6662b7bf7d5ed7510f075d5eff9f`
3. create the three kind clusters
4. enforce the `1g` memory limit on each kind node container
5. build and load Karmada images
6. deploy Karmada on `karmada-host`
7. join `member1` and `member2`

The fetched upstream source lives in `./karmada/` locally but is ignored by Git.

## Prerequisites

You need these tools installed locally:

- Docker
- kind
- kubectl
- git
- Go
- make
- python3

Quick check:

```bash
docker version
kind version
kubectl version --client
git --version
go version
make --version
python3 --version
```

## Quick start

```bash
git clone <your-repo-url>
cd karmada-kind
./scripts/cleanup.sh
./scripts/bootstrap-karmada.sh
./scripts/status.sh
./scripts/capture-artifacts.sh
```

## Key environment variables

- `HOST_IPADDRESS` — override the detected host IP for kind API server exposure
- `NODE_MEMORY_LIMIT` — defaults to `1g`
- `CLUSTER_VERSION` — defaults to `kindest/node:v1.35.0`
- `BUILD_IMAGES` — defaults to `true`
- `KARMADA_REPO_URL` — defaults to upstream Karmada GitHub repo
- `KARMADA_REF` — defaults to pinned commit `3424bc71d1bd6662b7bf7d5ed7510f075d5eff9f`

Example:

```bash
HOST_IPADDRESS=192.168.1.124 NODE_MEMORY_LIMIT=1g ./scripts/bootstrap-karmada.sh
```

## Files written during bootstrap

- generated kubeconfigs: `./.state/kubeconfig/`
- logs and helper binaries: `./.state/`
- proof bundles: `./artifacts/`
- fetched upstream source: `./karmada/`

## Example verification commands

```bash
./scripts/status.sh
kubectl --kubeconfig ./.state/kubeconfig/karmada.config --context karmada-apiserver get clusters.cluster.karmada.io
docker ps --format '{{.Names}}' | grep -E '^(karmada-host|member1|member2)-(control-plane|worker|worker2|worker3)$' | wc -l
./scripts/capture-artifacts.sh
```

## Cleanup

Remove clusters and generated state:

```bash
./scripts/cleanup.sh
```

Also remove the fetched upstream source checkout:

```bash
CLEAN_KARMADA_SOURCE=true ./scripts/cleanup.sh
```

## Notes

- This wrapper intentionally uses `3` clusters, not the broader defaults some upstream local scripts bring up.
- The repo is intended to be committable and shareable on GitHub without bundling generated artifacts or the full upstream Karmada checkout.
