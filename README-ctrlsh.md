# Shannon via `ctrl.sh` — run & manage scans

`ctrl.sh` runs the Shannon pentest scanner **entirely in Docker**. Your host needs
only Docker — Node, pnpm, git, and all compilation happen inside a toolchain image
(`Dockerfile.ctrl`). It targets z.ai's GLM models via the Anthropic-compatible endpoint.

- **Commands run any function directly:** `./ctrl.sh <function> [args]`.
- **Everything lives under `DATA_ROOT`** (set in `.env-ctrlsh`): this repo plus every scan
  target. It is mounted 1:1 into the container so the worker containers get valid paths.
- **Config & secrets** live in `.env-ctrlsh` (gitignored) — copy `.env-ctrlsh.example`,
  and set `DATA_ROOT`, your z.ai key, and the per-tier model ids.
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
# then edit .env-ctrlsh: set DATA_ROOT, ZAI_API_KEY, and the ANTHROPIC_*_MODEL ids
cp ctrl.local.sh.example ctrl.local.sh   # optional: add your scan targets
```

### 3. Build (one-time)
```bash
./ctrl.sh build
```
Builds the toolchain image, compiles the CLI + worker, and builds the `shannon-worker`
image. **Note:** the worker image's final layer does a recursive `chown` and can take
several minutes on slow disks — this is normal.

### 4. Run a scan
Define a target in `ctrl.local.sh`, then call it:
```bash
./ctrl.sh sources_mytarget     # assemble the combined source tree (optional helper)
./ctrl.sh scan_mytarget        # run the scan
```

### 5. Monitor
```bash
./ctrl.sh shannon status              # running scans
./ctrl.sh shannon logs <workspace>    # live log for a workspace
# Dashboard: http://localhost:8233
```
The report lands at `workspaces/<workspace>/Security-Assessment-Report.md`.

### 6. Stop / clean up
```bash
./ctrl.sh shannon stop                # stop, keep all data
./ctrl.sh shannon stop --clean        # stop + wipe Temporal volumes
rm -rf workspaces/*                   # delete scan outputs (optional)
docker rmi shannon-worker shannon-ctrl # remove images (optional)
```

---

## Quotas & resume

Scan configs using `retry_preset: subscription` **pause and resume automatically** when the
z.ai quota runs out and the window refreshes — no action needed. If you stop it or the
machine reboots, just **re-run the same scan command**; it resumes the same workspace and
skips already-completed agents.

---

## Add a new target

Copy a function in `ctrl.local.sh` and give it a URL, source repo, config, and workspace:

```bash
scan_mytarget() {
  shannon start -u https://my.target/ \
    -r "${DATA_ROOT}/my-repo" -c "${CFG}/my-target.yaml" -w my-target
}
```

Then run `./ctrl.sh scan_mytarget`. Create `apps/worker/configs/my-target.yaml` by copying an
existing one and editing the login / `success_condition` / rules. For an **unauthenticated**
target, drop the `authentication:` block and keep just `description` + `rules_of_engagement`
+ `pipeline.retry_preset`.

---

## Best-coverage tips

- **More source = better whitebox.** Shannon mounts one `-r` path. Assemble one directory
  with all relevant source (deployment config + connector code + UI) and point the
  target's `-r` at it — a `sources_*` helper is the place to do this.
- **Cost:** every extra target and repo uses more quota. Prioritise the highest-value
  surfaces (backend/API) per token; add frontends (XSS) and participants as budget allows.

---

## Notes & caveats

- **z.ai endpoint** must be the Anthropic-compatible one (`…/api/anthropic`), set via
  `ZAI_BASE_URL` in `.env-ctrlsh`. GLM support comes from a small committed patch in
  `apps/worker/src/ai/models.ts` and `apps/worker/src/services/preflight.ts` (clones a
  built-in Anthropic model for unknown custom-base-URL models).
- **Files are created as your uid/gid** (`ctrl.sh` runs the container with `--user`), so
  clones, build output, and reports are owned by you, not root.
