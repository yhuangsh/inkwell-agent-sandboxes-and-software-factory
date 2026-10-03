# Plan: remove all OPENROUTER_* dependencies from the sandbox just scripts

## Goal

The sandbox chain — `just sbx mount <task>` → `just sbx lifecycle execute <run-id> "<prompt>"` (which runs `just adw sdlc` = the sssf factory inside the VM) → `just sbx lifecycle teardown <run-id>` — must work end-to-end with **zero** `OPENROUTER_*` environment variables. Credentials for the sandbox's pi already come from the host-mirrored pi registry (`pi_mirror.py` → `~/.pi/agent/models.json`, shipped by FILL); the minted OpenRouter runtime key and the host-only provisioning key are dead weight. Delete the whole mint/inject/revoke/reap apparatus.

## Current state (verified by reading the code)

OpenRouter appears in the sandbox machinery in exactly these places:

| File | OPENROUTER_* usage |
|---|---|
| `just/sandbox/lifecycle/create.just` | Preflight-fails without `OPENROUTER_PROVISIONING_KEY`; step 4 mints a `sbx-<run-id>` runtime key (curl POST `/api/v1/keys`), writes `.sandbox/runs/<id>.key` (0600), records `key_hash`/`limit`. `--limit` flag parsing exists only for the mint. |
| `just/sandbox/lifecycle/fill.just` | Reads `.sandbox/runs/<id>.key`, writes `OPENROUTER_API_KEY=<runtime key>` into `app/.env` on the VM; hard-fails if the key file is missing. |
| `just/sandbox/lifecycle/teardown.just` | Step 1 reads spend via the runtime key (`GET /api/v1/key`) or the provisioning key (`GET /api/v1/keys`); step 4 revokes via provisioning key; step 6 shreds the key file; step 7 gates on the key being absent from `/keys`. |
| `just/sandbox/manage/reap.just` | Entire recipe is GC for orphaned `sbx-*` OpenRouter keys; hard-requires `OPENROUTER_PROVISIONING_KEY`. |
| `just/sandbox/manage/mod.just` | `doctor` checks `OPENROUTER_PROVISIONING_KEY` is set, and checks the openrouter-only `models.json.tmpl` has rates. |
| `sandbox_mount/guest/provision.sh` | Step 4 falls back to `sandbox_mount/guest/models.json.tmpl` (openrouter-only, `apiKey: env:OPENROUTER_API_KEY`) and bakes the key in from `app/.env`. |
| `sandbox_mount/guest/models.json.tmpl` | The openrouter-only fallback template. |
| `sandbox_mount/host/run_record.py` | `FIELDS` includes `key_hash`, `limit`, `spend`; `_COERCE` has float coercion for `limit`/`spend`; docstrings justify the record as "the only way to learn which OpenRouter key to revoke". |
| `sandbox_mount/host/runs_table.py` | Renders a SPEND column from the record's `spend` field. |
| `just/sandbox/manage/list.just` | Header comments reference spend. |
| `just/sandbox/mod.just`, `just/sandbox/run/mod.just`, `just/sandbox/lifecycle/execute.just`, `just/sandbox/lifecycle/setup.just`, `just/sandbox/lifecycle/observe.just`, `just/sandbox/mount.just` | Header comments mention the provisioning key / runtime key boundary. |
| `.env.sample` | `OPENROUTER_PROVISIONING_KEY=` and `OPENROUTER_API_KEY=` entries + OpenRouter ZDR paragraph. |
| `README.md` (lines ~45, ~184), `TREE.md` (line ~22) | Install instructions mention `OPENROUTER_PROVISIONING_KEY`. |

**Files that need no change:** `just/sandbox/lifecycle/setup.just` (the gate already pings roster models through pi, checks pi-reported cost, and checks per-provider credentials in `models.json` — assertions C/D/E only need comment touch-ups), `just/sandbox/lifecycle/execute.just` (comment touch-up only), `just/sandbox/lifecycle/observe.just` (comment touch-up only), `just/sandbox/orch/mod.just` (header comment mentions "the provisioning key" — touch-up), `just/adws.just` (no OpenRouter at all).

## Changes

### 1. `just/sandbox/lifecycle/create.just` — drop the mint

- Change the recipe signature from `create RUN_ID *FLAGS:` to `create RUN_ID:` and delete the entire `--limit` flag-parsing block and the `LIMIT` variable.
- Delete the preflight check for `OPENROUTER_PROVISIONING_KEY` (keep the `ssh curl python3` binary check).
- Delete step 4 ("the runtime key") in its entirety: the `BODY`/`mktemp` shred machinery, the curl mint, the embedded python key-file writer, `KEY_FILE`, and the `run_record.py set ... key_hash=... limit=...` call. Simplify the `_on_exit` trap accordingly (it still prints the failure/teardown hint; it no longer has a `BODY` to shred).
- Keep the order: run id → run record → VM → wait-for-ssh → session id. Rewrite the header comment: the strict order is now "record before VM, so a crash anywhere leaves teardown a handle"; remove all key-mint rationale.
- Final output line changes from "no code and no secrets on the box yet" to something like "no code on the box yet".

### 2. `just/sandbox/lifecycle/fill.just` — drop the runtime-key injection

- Delete the `KEY_FILE` existence check, `RUNTIME_KEY` extraction, the `printf 'OPENROUTER_API_KEY=%s\n' | ssh ... cat > app/.env` block, and the `ENV_STAT` proof line.
- The pi-mirror block (`pi_mirror.py models|settings|config` piped over ssh) stays exactly as-is — it is now the **only** credential path, and it already hard-fails the fill if the host catalog is unreadable.
- Rewrite the header comment: ONE kind of secret crosses the wire now (host provider API keys inside `models.json`), stdin-only, 0600. Remove the runtime-key/fallback wording.

### 3. `just/sandbox/lifecycle/teardown.just` — drop spend capture, revoke, key gate

- Delete `KEY_FILE` and `API` variables and the `KEY_HASH=$("$RR" get ... key_hash)` read.
- Delete step 1 (spend). Per-run cost is still observable — it comes from pi's own accounting in the trace db (`just obs sessions` shows `total_cost`), and setup gate D already proves the rate table is loaded. Say so in the header comment.
- Delete step 4 (revoke the key).
- In step 6, delete the key-file shred block; keep `run_record.py close`.
- Delete step 7 (key-absent gate). The final success line becomes unconditional after record close.
- New step order: VM check → artifacts → harvest (failure still aborts before destroy — unchanged) → destroy VM → close record. Rewrite the header: the order rationale is now "everything that READS the box runs before the one thing that destroys it"; remove key-ordering rationale. The `--no-harvest` flag stays.

### 4. Delete `just/sandbox/manage/reap.just`

No keys are ever minted, so there is nothing to reap. Remove the file and remove `import 'reap.just'` from `just/sandbox/manage/mod.just`.

### 5. `just/sandbox/manage/mod.just` — doctor without OpenRouter

- Header comment: remove "reap cannot list or delete without OPENROUTER_PROVISIONING_KEY, and doctor checks for it".
- `doctor` recipe:
  - Delete the `chk "OPENROUTER_PROVISIONING_KEY set"` line.
  - Replace the `chk "models template has rates"` line (the template is being deleted) with a host-catalog check that proves FILL will succeed, e.g.:
    `chk "host pi catalog readable" 'uv run --quiet sandbox_mount/host/pi_mirror.py models | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get(\"providers\")"'`
    (This pipes the secret-bearing document into a validator that prints nothing — same discipline as fill.just: never echo it.)
  - Keep the other checks (`ssh exe.dev reachable`, `run_record helper runs`, `provisioner present`, `adw layer resolves`).

### 6. `sandbox_mount/guest/provision.sh` — registry is mandatory, no fallback

- Step 4: if `$HOME/.pi/agent/models.json` is missing or empty, **hard-fail** with a message naming the fix (`re-run: just sbx lifecycle fill <run-id>`) instead of falling back to the template. Delete the entire template branch: `TMPL`, the `.env` grep for `OPENROUTER_API_KEY`, the bake-in substitution, and the "env: placeholder" warning.
- Keep the happy path ("FILL shipped the host-mirrored registry — keeping it") as-is. Step numbering (1/9 … 9/9) is unchanged since step 4 itself remains.

### 7. Delete `sandbox_mount/guest/models.json.tmpl`

Nothing references it after changes 5 and 6. Verify with `grep -rn "models.json.tmpl" just/ sandbox_mount/` before deleting (fix any straggler reference; `pi_mirror.py` mentions it in a comment — see change 8).

### 8. `sandbox_mount/host/run_record.py` — slim the schema

- Remove `key_hash`, `limit`, `spend` from `FIELDS`; remove `limit`/`spend` from `_COERCE`.
- Update the module docstring and the `create()`/`close()`/`list_runs()` comments: the record is still the only cross-phase state, but the "which key to revoke" rationale is gone — replace with "which VM to destroy and which commits to harvest".
- Backward compatibility: existing `.sandbox/runs/*.json` files with the old keys still load (`json.loads` of the whole record is tolerant; only `get <field>` validates names, and nothing requests the old names anymore). Old `.sandbox/runs/*.key` files, if any, are inert — do not add migration code; mention in the commit message that they can be deleted by hand.

### 9. `sandbox_mount/host/runs_table.py` + `just/sandbox/manage/list.just` — drop the SPEND column

- `runs_table.py`: remove the SPEND column from the header and row format; drop the `spend` handling; update the docstring (the "legitimately-empty fields" example goes away — keep the tab-delimited-loop rationale or simplify it to match).
- `list.just`: header comments no longer mention spend; the recipe body is unchanged (it just pipes records to `runs_table.py`).

### 10. Comment touch-ups (no behavior change)

- `just/sandbox/mod.just` header: replace "the exe.dev account and the OpenRouter provisioning key never leave the host" with "the exe.dev account never leaves the host"; the `sbx`-cannot-be-used-inside-a-sandbox rationale becomes just the exe.dev credential.
- `just/sandbox/run/mod.just` and `just/sandbox/lifecycle/execute.just` headers: delete the "OPENROUTER_PROVISIONING_KEY is never read in this file and must never be" paragraphs (the key no longer exists anywhere, so the warning is moot) — or rewrite as "no sandbox-minted credentials exist; the only host-only credential is the exe.dev account". Builder's choice, but no stale `OPENROUTER_` text may remain.
- `just/sandbox/lifecycle/setup.just`: header paragraph "The OpenRouter PROVISIONING key never appears…" and the inline comments in C/D/E that mention the OpenRouter runtime key — rewrite to reflect that pi-mirrored credentials are the only path.
- `just/sandbox/lifecycle/observe.just`: delete the "no OpenRouter key of either kind is read" sentence (moot).
- `just/sandbox/orch/mod.just` header: "it needs the exe.dev account and the provisioning key" → "it needs the exe.dev account".
- `just/sandbox/mount.just`: no OpenRouter text today, but confirm the chain line `just sbx lifecycle create "{{RUN_ID}}" {{FLAGS}}` is updated — `mount` currently forwards `{{FLAGS}}` (only ever used for `--limit`). Change `mount RUN_ID *FLAGS:` to `mount RUN_ID:` and call `just sbx lifecycle create "{{RUN_ID}}"`.

### 11. `.env.sample`, `README.md`, `TREE.md`

- `.env.sample`: delete the `OPENROUTER_PROVISIONING_KEY` and `OPENROUTER_API_KEY` sections and the OpenRouter ZDR paragraph. Replace the top blurb: credentials now live in the host pi agent's registry (`~/.pi/agent/auth.json` + `models-store.json`); FILL mirrors them into each sandbox. Keep the optional-overrides section.
- `README.md` lines ~45 and ~184: `cp .env.sample .env  # add OPENROUTER_PROVISIONING_KEY` → drop the key comment; if the surrounding text describes the mint/revoke model, adjust the sentence to the pi-mirror model. Keep the edits minimal — this task is about the just scripts, not a README rewrite.
- `TREE.md` line ~22: same minimal fix for the `.env.sample` description.

## Out of scope (note for follow-up, do NOT do in this change)

- `.claude/skills/sssf-sandbox-orchestrator/SKILL.md` and its cookbooks (`debug_a_failed_gate.md`, `fan_out_n.md`, `just_command_model.md`, `teardown_and_reap.md`) still describe the OpenRouter mint/revoke/reap world extensively. That is a documentation rewrite of its own; flag it in the final summary.
- `ai_docs/exedev_sandbox_mounting.md` historical references — leave alone (historical research notes).

## Verification (in order)

1. **Zero-reference gate:**
   `grep -rn "OPENROUTER" just/ sandbox_mount/ .env.sample README.md TREE.md` → no matches. (`ai_docs/`, `.claude/`, `specs/`, `adws/adw_data/` keep historical mentions — excluded deliberately.)
2. **Justfile parses:** `just --list` and `just --list sbx`, `just --list sbx::lifecycle`, `just --list sbx::manage` all succeed; `reap` is gone from the manage listing.
3. **run_record still works:** `sandbox_mount/host/run_record.py list` exits 0 (also with pre-existing records present); `run_record.py new-id smoke` prints an id.
4. **Doctor passes with no OpenRouter env:** `env -u OPENROUTER_API_KEY -u OPENROUTER_PROVISIONING_KEY just sbx manage doctor` → `sbx doctor: OK`.
5. **End-to-end live run** (this is the task's acceptance — it boots a real exe.dev VM):
   ```
   just sbx mount smoke-no-openrouter
   just sbx lifecycle execute <run-id> "Add a one-line summary of this repo to specs/585c36b3_repo-one-line-summary.md"   # or any tiny prompt
   just sbx run cmd <run-id> 'tail -f run.log'   # watch the sssf ADW run inside the sandbox
   just sbx manage harvest <run-id>
   just sbx lifecycle teardown <run-id>
   ```
   Success = mount's gate passes (setup assertions A–E run purely on the pi-mirrored registry), the detached `adw sdlc` run completes inside the VM, harvest bundles the commits, teardown destroys the VM and closes the record — all with no `OPENROUTER_*` variable set in the environment.
6. **provision.sh failure path** (optional but cheap): `just sbx run cmd <run-id> 'rm ~/.pi/agent/models.json && bash app/sandbox_mount/guest/provision.sh'` should fail loudly naming FILL, not silently write a template registry. Only if a sacrificial VM is still up; otherwise skip.

## Risks / notes for the builder

- Six phase files are `import`ed into `just/sandbox/lifecycle/mod.just` and share ONE scope: no new top-level `foo :=` variables, no `set` lines in phase files. Deleting code is safe; adding either is a parse error.
- An unindented line inside a recipe body terminates the recipe — keep every line of the bash bodies indented, including heredoc contents (the existing files use indented heredocs deliberately).
- `fill.just`'s pi-mirror block pipes live provider keys; never add an `echo`/temp file that touches that stream.
- Do not touch `just/adws.just`, `adws/`, or `adws/adw_sssf_config/*.yaml` — the in-sandbox factory layer has no OpenRouter dependency.
