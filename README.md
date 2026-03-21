# karmada-kind

Reproducible local Karmada-on-kind workspace.

## Goal

Bring up a **3-cluster** Karmada environment using kind with:
- `karmada-host`
- `member1`
- `member2`
- **12 kind node containers total**
- **1 GiB memory limit per kind node container**

## Repo layout

- `karmada/` — upstream cloned Karmada repo
- `configs/kind/` — checked-in kind topologies
- `scripts/bootstrap-karmada.sh` — main setup entrypoint
- `scripts/cleanup.sh` — deletes the local project clusters
- `scripts/status.sh` — summarizes current environment state
- `RUNBOOK.md` — reproducibility workbook / operating procedure

## Quick start

```bash
./scripts/cleanup.sh
./scripts/bootstrap-karmada.sh
./scripts/status.sh
```

## Important

The upstream `karmada/hack/local-up-karmada.sh` script creates **4 clusters**, not 3. This repo uses a custom top-level bootstrap so the topology matches the stated requirement.
