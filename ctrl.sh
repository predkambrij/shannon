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
: "${SHANNON_AI_MODEL:?set SHANNON_AI_MODEL in .env-ctrlsh}"
: "${DOCKER_SOCKET_PATH:?set DOCKER_SOCKET_PATH in .env-ctrlsh}"

pi_auth_value="${SHANNON_USE_PI_AUTH:-0}"
case "${pi_auth_value,,}" in
  1|true)
    SHANNON_USE_PI_AUTH=1
    export SHANNON_USE_PI_AUTH
    ;;
  0|false|'')
    SHANNON_USE_PI_AUTH=0
    export SHANNON_USE_PI_AUTH
    : "${SHANNON_AI_BASE_URL:?set SHANNON_AI_BASE_URL in .env-ctrlsh}"
    : "${SHANNON_AI_API_KEY:?set SHANNON_AI_API_KEY in .env-ctrlsh}"
    ;;
  *)
    echo "ctrl.sh: SHANNON_USE_PI_AUTH must be 1/true or 0/false." >&2
    exit 1
    ;;
esac
unset pi_auth_value

# ── Layout ───────────────────────────────────────────────────────────────────
CTRL_IMAGE="shannon-ctrl"   # toolchain image (Dockerfile.ctrl)
CFG="apps/worker/configs"   # per-target scan configs

# ── Docker plumbing ──────────────────────────────────────────────────────────
# Run a command in the toolchain container: host docker socket + data root mounted at
# its real path so worker sibling-containers get valid mounts. Runs as your uid/gid
# (+ the host docker group for socket access) so created files are yours, not root.
# HOME is a persistent cache so pnpm/corepack aren't re-fetched. Model settings
# pass as env (the Shannon CLI reads them directly — no repository .env needed).
dctl() {
  local tty=(); [ -t 1 ] && tty=(-t)
  mkdir -p "${DATA_ROOT}/.shannon-ctrl-home"
  docker run --rm -i "${tty[@]}" \
    --user "$(id -u):$(id -g)" \
    --group-add "$(getent group docker | cut -d: -f3)" \
    -v "${DOCKER_SOCKET_PATH}:/var/run/docker.sock" \
    -v "${DATA_ROOT}:${DATA_ROOT}" \
    -v "${PWD}:${PWD}" \
    -w "${PWD}" \
    -e "HOME=${DATA_ROOT}/.shannon-ctrl-home" \
    -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    -e SHANNON_AI_BASE_URL \
    -e SHANNON_AI_API_KEY \
    -e SHANNON_AI_MODEL \
    -e SHANNON_USE_PI_AUTH \
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

# Authenticate Pi with a ChatGPT Plus/Pro subscription. Pi is already a worker
# dependency; its OAuth state is stored under the persistent toolchain HOME and
# Shannon mounts that single auth file into each worker when a scan starts.
chatgpt_login() {
  local pi_bin="apps/worker/node_modules/.bin/pi"
  if [ ! -x "${pi_bin}" ]; then
    echo "ctrl.sh: Pi is not installed yet — run './ctrl.sh build' first." >&2
    return 1
  fi
  printf '%s\n' \
    "In Pi, enter /login and choose ChatGPT Plus/Pro (Codex)." \
    "Complete the browser or device-code flow, then press Ctrl-D to return." \
    "Credentials persist in ${DATA_ROOT}/.shannon-ctrl-home/.pi/agent/auth.json." \
    ""
  dctl "${pi_bin}" --no-approve --no-session
}

function git_diff_local() {
    git diff -w --no-index ctrl.local.sh.example ctrl.local.sh || true
    git diff -w --no-index .env-ctrlsh.example .env-ctrlsh || true
}

# ── Personal scan targets (gitignored, optional) ──────────────────────────────
# Define your scan_*/sources_* helpers in ctrl.local.sh — see ctrl.local.sh.example.
# ctrl.sh exposes shannon(), dctl(), and $DATA_ROOT / $CFG for them to use.
[ -f ctrl.local.sh ] && . ./ctrl.local.sh

# Dispatch: run the named function directly. Examples:
#   ./ctrl.sh build
#   ./ctrl.sh chatgpt_login
#   ./ctrl.sh shannon status
#   ./ctrl.sh shannon logs <workspace>
#   ./ctrl.sh shannon stop
#   ./ctrl.sh <your_target_fn>        # defined in ctrl.local.sh
"$@"
