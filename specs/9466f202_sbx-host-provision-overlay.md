# Plan: fix `just sbx mount` gate-B failure — run the host's provision.sh on the VM

## Root cause (verified by recon)

`just sbx mount` → `fill` clones `https://github.com/disler/inkwell-agent-sandboxes-and-software-factory.git`
(hardcoded as `REPO` in `just/sandbox/lifecycle/fill.just`, line ~30) and `setup` then runs the
**cloned** `app/sandbox_mount/guest/provision.sh`. The clone's HEAD is `92f17018`, whose
`provision.sh` has **no node/npm bootstrap and no pi-install step**, so gate B's
`npm view @earendil-works/pi-coding-agent version` (setup.just REMOTE_B) dies with
`bash: line 10: npm: command not found` right after printing
`npm view failed — cannot verify pi currency`.

The fix (node 22 bootstrap from nodejs.org, `/usr/local/bin` symlinks, `npm install -g
@earendil-works/pi-coding-agent@<latest>`, `/usr/local/bin/pi` relink, hard version-parity
assertion) already exists locally as `sandbox_mount/guest/provision.sh` step 4/9, committed
in `c0ec04b`. Local `main` (`4fd57b9`) is 7 commits ahead of `92f17018`.

## Why "push the fix" is NOT the plan — read this before implementing

Publishing `c0ec04b` to a remote cannot reach the VM:

- The VM clones the **`disler`** repo (upstream). Verified: **no credential on this machine
  has push access to it** — both the `gh` token (account `yhuangsh`) and the stored
  `x-access-token` report `permissions.push: false` on
  `disler/inkwell-agent-sandboxes-and-software-factory`.
- The pushable remote is the `yhuangsh` fork (`origin`), but the VM never clones it, and
  **changing which repo gets cloned is explicitly out of scope**.
- `fill`'s optional SHA pin doesn't help either: a pin must resolve inside the clone, and
  local commits are in no public repo the clone can see.
- Overwriting `app/sandbox_mount/guest/provision.sh` on the VM is also out: gate A requires
  `git status --porcelain` to be **clean** — any write into the tracked tree fails gate A.

The only architecture that satisfies the done-criteria under these constraints: **the setup
phase pipes the host's own `provision.sh` to the VM over ssh stdin** and runs that, instead of
executing the file inside the clone. The clone source, the teardown phase, and the
registry-`latest` (unpinned) pi install all stay exactly as they are. This is also robust
going forward: the provisioner becomes host-controlled and immune to clone staleness, which
matters because the clone source is a third-party read-only repo.

## Changes

### 1. `sandbox_mount/guest/provision.sh` — accept a repo-root override

The script derives `REPO_ROOT` from `BASH_SOURCE`; when piped via `bash -s`, `BASH_SOURCE`
is useless and the derivation would resolve to the wrong directory. Add an env override at
the top of step 1 (keep the existing derivation as the fallback):

```bash
# ── 1. locate the repo ───────────────────────────────────────────────────────
# REPO_ROOT comes from PROVISION_REPO_ROOT when set (setup.just pipes this script
# to the VM over ssh stdin, where BASH_SOURCE is meaningless), else from this
# script's own path, never hardcoded to /home/exedev/app.
if [[ -n "${PROVISION_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$PROVISION_REPO_ROOT"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
cd "$REPO_ROOT"
```

Also update the header comment block: document both invocation forms —
`ssh <vm> 'bash app/sandbox_mount/guest/provision.sh'` (in-clone) and
`ssh <vm> 'PROVISION_REPO_ROOT="$HOME/app" bash -s' < provision.sh` (host-piped) — and one
sentence on WHY the host-piped form exists (the clone source is a read-only third-party
repo; local provisioner fixes can never reach the VM through the clone).

No other step changes. Step 4/9 (node bootstrap + pi latest) stays as committed in `c0ec04b`.

### 2. `just/sandbox/lifecycle/setup.just` — provision from the host checkout

In the `── 1. provision ──` section, replace:

```bash
"${SSH[@]}" 'bash app/sandbox_mount/guest/provision.sh' < /dev/null \
  || gate_fail "provision.sh exited non-zero (its last '── step ──' line names the stage)"
```

with (recipes run from the root justfile's directory, so the relative path resolves):

```bash
"${SSH[@]}" 'PROVISION_REPO_ROOT="$HOME/app" bash -s' < sandbox_mount/guest/provision.sh \
  || gate_fail "provision.sh exited non-zero (its last '── step ──' line names the stage)"
```

Notes for the edit:

- `< /dev/null` on this line is **replaced** by the file redirect — the script now arrives
  on stdin. Keep `< /dev/null` on the surrounding ssh calls unchanged.
- `"$HOME/app"` stays inside single quotes so `$HOME` expands on the VM, not the host.
- Update the section's comment and the header comment of the file ("run provision.sh inside
  the sandbox") to say the provisioner is streamed from the HOST checkout, and why: the VM's
  clone comes from a third-party public repo this machine cannot push to, so a
  provisioner fix committed locally could never otherwise reach the box; and gate A forbids
  writing the script into the tracked `app/` tree. Mention that the provisioner that runs is
  whatever the host working tree has — that is intentional (host-controlled provisioning).

Nothing else in setup.just changes: sentinel poll, gate A–E scripts, `gate_fail` all stay.

### 3. (Optional hygiene, do not block on it) publish the local commits

`git push origin main` (the `yhuangsh` fork — push access verified) so `c0ec04b` and the
other 6 commits exist on at least one remote branch. This does NOT affect the mount (the VM
clones `disler`, untouched), it's just backup/publish hygiene. Skip if the operator prefers.

## Explicitly NOT doing

- Not changing `fill.just`'s `REPO` / clone source (out of scope — and the fork is not
  cloned by the VM anyway).
- Not touching teardown (out of scope).
- Not pinning a pi version — `npm view ... version` / `@latest` resolution stays (out of scope).
- Not writing anything into the VM's `app/` tree (gate A demands a clean tree).
- Not pushing to `upstream` (disler) — impossible, no push permission; do not attempt PRs.

## Verification

1. (Evidence, optional but cheap) Confirm the root cause on the failed VM left up:
   ```bash
   uv run sandbox_mount/host/run_record.py list
   ssh inkwell-1-20261004-977869.exe.xyz 'grep -c "nodejs.org" app/sandbox_mount/guest/provision.sh; node --version; npm --version'
   ```
   Expect count `0` and `command not found` for node/npm.
2. Sanity-check the edited scripts: `bash -n sandbox_mount/guest/provision.sh`, and
   `shellcheck sandbox_mount/guest/provision.sh` if shellcheck is on PATH. Also
   `just --summary >/dev/null` (or `just --list | grep -q 'sbx'`) to prove setup.just still parses.
3. Full end-to-end on a FRESH run (the done condition):
   ```bash
   just sbx mount fix-npm-1-$(date +%Y%m%d)-$RANDOM
   ```
   Watch for, in order: provision step `4/9 pi agent (latest)` bootstrapping Node and
   printing `pi <ver> (registry latest)`; sentinel present; then
   `[gate] A PASS`, `[gate] B PASS  pi current ...` (the previously failing line),
   `C PASS`, `D PASS`, `E PASS`, and finally `GATE PASSED`.
4. Cross-check on the new VM directly:
   ```bash
   uv run sandbox_mount/host/run_record.py list   # get the new vm_name
   ssh <new-vm>.exe.xyz 'node --version && npm --version && pi --version && ls -l /usr/local/bin/pi'
   ```
   `pi --version` must equal `npm view @earendil-works/pi-coding-agent version` (host side).
5. Leave teardown of both VMs as an explicit operator decision
   (`just sbx lifecycle teardown <run-id>`) — per the mount design, never chain it.

## Risks / gotchas

- The provisioner that runs is the host's **working-tree** copy of provision.sh — if the
  builder has uncommitted WIP in that file, that's what lands on the VM. Expected behavior
  of the new design; just be aware.
- The VM still runs the *rest* of the repo (adws code etc.) from the `92f17018` clone.
  Gates A–E don't depend on the newer in-repo code (the roster and `app/.env` are shipped
  verbatim by `fill` from the host), so this is fine for the mount done-condition.
- If `just sbx mount` fails again at gate B with `npm view failed`, the cause is network
  egress to the npm registry from the VM, not this change — the error text distinguishes them.
