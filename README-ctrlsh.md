# Shannon via `ctrl.sh` — run & manage scans

`ctrl.sh` runs the Shannon pentest scanner **entirely in Docker**. Your host needs
only Docker — Node, pnpm, git, and all compilation happen inside a toolchain image
(`Dockerfile.ctrl`). It supports a ChatGPT Plus/Pro subscription through OpenAI Codex,
as well as z.ai's GLM models through the Anthropic-compatible endpoint.

- **Commands run any function directly:** `./ctrl.sh <function> [args]`.
- **`DATA_ROOT`** is set locally in each target function in `ctrl.local.sh` to mount
  its source directory. Build, login, and management commands need no `DATA_ROOT`.
  Toolchain cache and Pi login are shared across targets in the Shannon repo’s
  `.shannon-ctrl-home/` directory.
- **Config & secrets** live in `.env-ctrlsh` (gitignored) — copy `.env-ctrlsh.example`,
  and select either the ChatGPT subscription or z.ai block.
- **Personal scan targets** live in `ctrl.local.sh` (gitignored) — copy
  `ctrl.local.sh.example` and add your own `scan_*`/`sources_*` functions. `ctrl.sh`
  sources it automatically if present.

---

## Chronological setup

### 1. Prerequisite
Docker installed and running. That's it.

### 2. Config (one-time)
```bash
cp .env-ctrlsh.example .env-ctrlsh
# then edit .env-ctrlsh: choose one provider block
cp ctrl.local.sh.example ctrl.local.sh   # optional: add your scan targets
```

### 3. Build (one-time)
```bash
./ctrl.sh build
```
Builds the toolchain image, compiles the CLI + worker, and builds the `shannon-worker`
image. **Note:** the worker image's final layer does a recursive `chown` and can take
several minutes on slow disks — this is normal.

### 4. ChatGPT subscription login (one-time, subscription users only)

With the ChatGPT block enabled in `.env-ctrlsh`, start Pi's login UI:

```bash
./ctrl.sh chatgpt_login
```

Enter `/login`, select **ChatGPT Plus/Pro (Codex)**, and complete the browser or
device-code flow. The OAuth credential is stored at
`<shannon-repo>/.shannon-ctrl-home/.pi/agent/auth.json`, where it survives toolchain
containers and can be refreshed by scan workers. All targets reuse this login.
The directory is excluded from Git and Docker build contexts. Treat that file like a password.

To reuse an existing login from the old location, run this from the Shannon repo
(replace `/old/data-root` with the `DATA_ROOT` used for that login):

```bash
mkdir -p .shannon-ctrl-home/.pi/agent
cp -n /old/data-root/.shannon-ctrl-home/.pi/agent/auth.json .shannon-ctrl-home/.pi/agent/
```

This uses `SHANNON_USE_PI_AUTH=1` with an `openai-codex:` model; it does not use or
bill an OpenAI API key. OpenAI documents the distinction between subscription and
usage-based Codex authentication in its [authentication guide](https://learn.chatgpt.com/docs/auth).

### 5. Run a scan
Define a target in `ctrl.local.sh`, then call it:
```bash
./ctrl.sh sources_mytarget     # assemble the combined source tree (optional helper)
./ctrl.sh scan_mytarget        # run the scan
```

### 6. Monitor
```bash
./ctrl.sh shannon status              # running scans
./ctrl.sh shannon logs <workspace>    # live log for a workspace
# Dashboard: http://localhost:8233
```
The report lands at `workspaces/<workspace>/Security-Assessment-Report.md`.

### Pause / unpause a worker (eg. around usage limits)

Find the worker's name with `docker ps`, then pause or unpause it directly:

```bash
dockerr pause shannon-worker-fdd09c6a
# When ready to continue:
docker unpause shannon-worker-fdd09c6a
```

### 7. Stop / clean up
```bash
./ctrl.sh shannon stop                # stop, keep all data
./ctrl.sh shannon stop --clean        # stop + wipe Temporal volumes
rm -rf workspaces/*                   # delete scan outputs (optional)
docker rmi shannon-worker shannon-ctrl # remove images (optional)
```

---

## Add a new target

Copy a function in `ctrl.local.sh` and give it a URL, source repo, config, and workspace:

```bash
scan_mytarget() {
  local DATA_ROOT="/absolute/path/to/my-repo"
  shannon start -u https://my.target/ \
    -r "${DATA_ROOT}" -c "${CFG}/my-target.yaml" -w my-target
}
```

Each target’s local `DATA_ROOT` controls its data mount. No global `DATA_ROOT` is
required in `.env-ctrlsh`. The toolchain cache and Pi credentials stay in the
Shannon repo’s `.shannon-ctrl-home/`, so each target reuses the same login.

Then run `./ctrl.sh scan_mytarget`. Create `apps/worker/configs/my-target.yaml` by copying an
existing one and editing the login / `success_condition` / rules. For an **unauthenticated**
target, drop the `authentication:` block and keep `description`, `rules_of_engagement`,
and any relevant `rules`.

---

## Best-coverage tips

- **More source = better whitebox.** Shannon mounts one `-r` path. Assemble one directory
  with all relevant source (deployment config + connector code + UI) and point the
  target's `-r` at it — a `sources_*` helper is the place to do this.
- **Cost:** every extra target and repo uses more quota. Prioritise the highest-value
  surfaces (backend/API) per token; add frontends (XSS) and participants as budget allows.

---

## Notes & caveats

- **ChatGPT subscription** uses Shannon's Pi credential-reuse path. Keep
  `SHANNON_USE_PI_AUTH=1` and use an `openai-codex:` model such as
  `openai-codex:gpt-5.6-sol`. Do not set an API key or custom base URL for this mode.
- **z.ai endpoint** must be the Anthropic-compatible one (`…/api/anthropic`), set via
  `SHANNON_AI_BASE_URL` in `.env-ctrlsh`. Shannon v2.6 natively accepts model ids that
  are absent from pi's catalogue when a custom endpoint is configured; the
  `anthropic:` prefix in `SHANNON_AI_MODEL` selects the expected wire protocol.
- **One model runs every phase** in v2.6. The example uses the medium GLM model,
  whose 1M context window is sufficient for the report phase, so no large-tier
  override is needed.
- **Files are created as your uid/gid** (`ctrl.sh` runs the container with `--user`), so
  clones, build output, and reports are owned by you, not root.
