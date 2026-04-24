#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KARMADA_REPO="${ROOT_DIR}/karmada"
KARMADA_REPO_URL="${KARMADA_REPO_URL:-https://github.com/karmada-io/karmada.git}"
KARMADA_REF="${KARMADA_REF:-3424bc71d1bd6662b7bf7d5ed7510f075d5eff9f}"
PATCHES_DIR="${ROOT_DIR}/patches/upstream"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd git

if [[ ! -d "${KARMADA_REPO}/.git" ]]; then
  echo "Cloning upstream Karmada source into ${KARMADA_REPO}"
  git clone "${KARMADA_REPO_URL}" "${KARMADA_REPO}"
fi

current_remote=$(git -C "${KARMADA_REPO}" remote get-url origin 2>/dev/null || true)
if [[ -n "${current_remote}" ]] && [[ "${current_remote}" != "${KARMADA_REPO_URL}" ]]; then
  echo "WARN: existing Karmada checkout has remote '${current_remote}', expected '${KARMADA_REPO_URL}'" >&2
fi

echo "Fetching upstream Karmada ref ${KARMADA_REF}"
git -C "${KARMADA_REPO}" fetch --tags origin
git -C "${KARMADA_REPO}" checkout "${KARMADA_REF}"
git -C "${KARMADA_REPO}" reset --hard "${KARMADA_REF}"
git -C "${KARMADA_REPO}" clean -fd

if [[ -d "${PATCHES_DIR}" ]]; then
  while IFS= read -r patch_file; do
    echo "Applying local reproducibility patch: ${patch_file}"
    git -C "${KARMADA_REPO}" apply "${patch_file}"
  done < <(find "${PATCHES_DIR}" -maxdepth 1 -type f -name '*.patch' | sort)
fi

echo "Pinned Karmada source ready at:"
echo "- repo: ${KARMADA_REPO}"
echo "- ref:  $(git -C "${KARMADA_REPO}" rev-parse HEAD)"
