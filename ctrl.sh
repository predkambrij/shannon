#!/usr/bin/env bash
#
# ctrl.sh — build & run Shannon entirely inside Docker. Host needs Docker only.
# Node/pnpm/git and compilation all happen in the toolchain image (Dockerfile.ctrl).
#
# Config & secrets live in .env-ctrlsh (gitignored) — see .env-ctrlsh.example.
# Personal scan targets live in ctrl.local.sh (gitignored, sourced if present) —
# see ctrl.local.sh.example.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ── Config / credentials — loaded from .env-ctrlsh (gitignored) ───────────────
if [ ! -f .env-ctrlsh ]; then
  echo "ctrl.sh: missing .env-ctrlsh — copy .env-ctrlsh.example to .env-ctrlsh and fill it in." >&2
  exit 1
fi
set -a; . ./.env-ctrlsh; set +a
: "${DATA_ROOT:?set DATA_ROOT in .env-ctrlsh}"
: "${ZAI_BASE_URL:?set ZAI_BASE_URL in .env-ctrlsh}"
: "${ZAI_API_KEY:?set ZAI_API_KEY in .env-ctrlsh}"
: "${ANTHROPIC_SMALL_MODEL:?set ANTHROPIC_SMALL_MODEL in .env-ctrlsh}"
: "${ANTHROPIC_MEDIUM_MODEL:?set ANTHROPIC_MEDIUM_MODEL in .env-ctrlsh}"
: "${ANTHROPIC_LARGE_MODEL:?set ANTHROPIC_LARGE_MODEL in .env-ctrlsh}"

# ── Layout ───────────────────────────────────────────────────────────────────
CTRL_IMAGE="shannon-ctrl"   # toolchain image (Dockerfile.ctrl)
CFG="apps/worker/configs"   # per-target scan configs

# ── Docker plumbing ──────────────────────────────────────────────────────────
# Run a command in the toolchain container: host docker socket + data root mounted at
# its real path so worker sibling-containers get valid mounts. Runs as your uid/gid
# (+ the host docker group for socket access) so created files are yours, not root.
# HOME is a persistent cache so pnpm/corepack aren't re-fetched. z.ai creds pass as
# env (the Shannon CLI reads them directly — no .env needed).
dctl() {
  local tty=(); [ -t 1 ] && tty=(-t)
  mkdir -p "${DATA_ROOT}/.shannon-ctrl-home"
  docker run --rm -i "${tty[@]}" \
    --user "$(id -u):$(id -g)" \
    --group-add "$(getent group docker | cut -d: -f3)" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${DATA_ROOT}:${DATA_ROOT}" \
    -w "${PWD}" \
    -e "HOME=${DATA_ROOT}/.shannon-ctrl-home" \
    -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    -e "ANTHROPIC_BASE_URL=${ZAI_BASE_URL}" \
    -e "ANTHROPIC_AUTH_TOKEN=${ZAI_API_KEY}" \
    -e ANTHROPIC_SMALL_MODEL \
    -e ANTHROPIC_MEDIUM_MODEL \
    -e ANTHROPIC_LARGE_MODEL \
    "${CTRL_IMAGE}" "$@"
}

# Run the Shannon CLI inside the container.
shannon() { dctl ./shannon "$@"; }

# ── build: toolchain image → compile repo → build the worker image ────────────
build() {
  docker build -f Dockerfile.ctrl -t "${CTRL_IMAGE}" .
  dctl bash -lc 'pnpm install && pnpm run build'
  shannon build
}

# ── Personal scan targets (gitignored, optional) ──────────────────────────────
# Define your scan_*/sources_* helpers in ctrl.local.sh — see ctrl.local.sh.example.
# ctrl.sh exposes shannon(), dctl(), and $DATA_ROOT / $CFG for them to use.
[ -f ctrl.local.sh ] && . ./ctrl.local.sh

# Dispatch: run the named function directly. Examples:
#   ./ctrl.sh build
#   ./ctrl.sh shannon status
#   ./ctrl.sh shannon logs <workspace>
#   ./ctrl.sh shannon stop
#   ./ctrl.sh <your_target_fn>        # defined in ctrl.local.sh
"$@"
