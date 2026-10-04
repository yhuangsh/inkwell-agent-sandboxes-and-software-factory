# Plan: Land generalization phases 0-1 (reconcile, verify for real, land)

## Why this run exists

Run 4c8321b5 implemented Phases 0-1 of the any-app factory-mount spec and
**verified them on real VMs** (run records `.sandbox/runs/sssfp01-20261004-abc123.json`
and `sssfp01f-20261004-def456.json` show `factory_sha` recorded, gates green,
in-sandbox quality 7/7 manifest-driven). It was then rolled back for touching
barred paths (`adws/adw_modules/agent_pi.py`). The verified work survives
**staged in the working tree right now**. This run: reconcile it against the
spec, re-perform the spec's verifications for real, land it — nothing more.

## Authority and hard boundaries

- **Spec (authoritative):** `adws/adw_data/sessions/6159cbd5/context_handoff/plan.md`
  (byte-identical: `specs/6159cbd5_any-app-factory-mount.md`). Phases **0 and 1
  only**. The predecessor's phase-scoped plan `specs/4c8321b5_app-manifest-phases-0-1.md`
  matches the staged work and is a useful cross-check, but the 6159cbd5 spec
  wins any disagreement.
- **This run's roster is `adws/adw_sssf_config/sssf.meta.config.yaml`.** The
  builder may modify EXACTLY these nine paths — anything outside them is
  rolled back again:
  - `adws/adw_modules/quality.py`
  - `adws/adw_modules/data_types.py`
  - `adws/adw_sssf_config/sssf.config.yaml`
  - `adws/adw_sssf_config/sssf.meta.config.yaml`
  - `just/sandbox/lifecycle/fill.just`
  - `just/sandbox/lifecycle/setup.just`
  - `sandbox_mount/guest/provision.sh`
  - `sandbox_mount/host/run_record.py`
  - `apps/inkwell/sssf.app.yaml`
- **`adws/adw_modules/agent_pi.py` must stay byte-identical to HEAD.** Its
  would-be diff is preserved at `/tmp/agent_pi_models_json_optional.patch`.
  Do NOT apply it. If verification proves models.json-optionality is genuinely
  required, that goes in the envelope as a finding (see Step 4).
- Also barred by the spec's own scope: `.gitignore` (`/target/` is Phase 2),
  `observe.just` / `harvest.just` / `teardown.just`, the other roster variants
  (deepestseek, frontier, open-weights, top-speed), any `app.repo`/`ref` clone
  logic, Phases 2-3 generally, the ref-publishing guard, the rollback-index
  bug, credential design.

## Current state (verified this session — trust these)

- `git status --short`: the eight phase 0/1 files staged (`M`/`A`), the meta
  roster untracked (`??`), nothing else. No unstaged modifications.
- HEAD = `9caf426` "Add spec for factory generalization phases 0-1", which
  already committed BOTH `specs/6159cbd5_any-app-factory-mount.md` and
  `specs/4c8321b5_app-manifest-phases-0-1.md`. **The spec commit already
  exists — do not re-create it.**
- `origin` = the engineer's public fork
  `https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git`,
  at `f6eca9e` (one behind local main). The host CAN push to it (4c8321b5
  pushed and deleted temp branches `sssf-verify-p01`, `sssf-verify-final`).
- FILL clones the factory from `origin` (fill.just line ~28), so **local
  uncommitted quality.py/data_types.py changes do NOT reach a VM through a
  plain fill** — that is why verification needs a temp branch (Step 2/4).
  `provision.sh` is different: setup.just streams the HOST working-tree file
  into the VM (line ~94), so its changes take effect on any mount.
- Gates B-E exercise the pi CLI directly (setup.just REMOTE_B/REMOTE_CDE) and
  never touch `agent_pi.py`; only the ADW layer (`adw *` chains) hits
  `agent_pi.context_window`.
- 4c8321b5's raw output contains the smoking gun, to be re-confirmed live:
  `FileNotFoundError: [Errno 2] No such file or directory:
  '/home/exedev/.pi/agent/models.json'` from `agent_pi.py` line 110
  (`context_window`), killing an in-sandbox `adw build-test`. fill.just
  line ~190 deletes `~/.pi/agent/models.json` on every fresh box, and
  `agent_pi.run()` calls `context_window()` for every agent invocation.

## Step 0 — Reconcile the staged work against the spec (review, not rewrite)

Read `git diff --cached` for all eight files plus the untracked roster, and
check each against the spec. Expected content (all confirmed present this
session — flag and fix-forward ONLY if you find a genuine discrepancy, and
only within the nine authorized paths):

- `adws/adw_modules/data_types.py` — `AppConfig` (repo/ref Optional, path
  default `apps/inkwell`, manifest default `sssf.app.yaml`) +
  `SSSFConfig.app` field. Phase-0 compat defaults, so rosters without the
  block still load.
- `adws/adw_sssf_config/sssf.config.yaml` — top-level `app:` block,
  `path: apps/inkwell`, `manifest: sssf.app.yaml`, no `repo:` (Phase 0).
- `sandbox_mount/host/run_record.py` — `"factory_sha"` added to `FIELDS`
  (the closed schema's one sanctioned extension).
- `just/sandbox/lifecycle/fill.just` — records `factory_sha="$HEAD_SHA"`
  right after `commit_sha`.
- `just/sandbox/lifecycle/setup.just` — gate A gains a **null-tolerant**
  factory_sha assertion (older records read empty → skip, never fail).
- `sandbox_mount/guest/provision.sh` — step `5/9 app` generic and
  manifest-driven: ONE parser (a `uv run` PEP-723 probe, pyyaml dep) reads
  `app.path`/`app.manifest` from `/home/exedev/sssf_config.yaml` and the
  manifest's `install`/`build`/`runtime`; unknown runtime fails fast BY NAME
  (never apt); absent manifest → `package.json` fallback (`bun install`);
  absent keys → skip with a `say` line. Step `6/9 visualizer` absorbs the
  visualizer's `bun install` (factory machinery). Steps 1-4, 7 (trace db),
  8 (warm uv), 9 (summary) byte-preserved; `touch /tmp/PROVISION_READY` is
  still the literal last line.
- `adws/adw_modules/quality.py` — manifest-driven: `_load_checks` reads
  `<repo_root>/<app.path>/<app.manifest>` `checks:` (yaml.safe_load — pyyaml
  is a PEP-723 dep of every adw script), substitutes `{outdir}` with the
  check's absolute bundle dir, maps `bun` → `BUN` (BUN_PATH escape hatch
  preserved), runs checks with cwd = the app dir. Public API: `run_quality`
  (NEW — all checks incl. `tests`; fixes the latently broken
  `adw_quality.py` / `adw_plan_build_test_quality.py` callers),
  `run_inkwell_quality` (all but `tests`), `run_inkwell_tests` (`tests`
  only). Callers verified intact: `adw_simple_sdlc.py`, `adw_build_test.py`,
  `adw_plan_build_test.py` → `run_inkwell_tests`.
- `apps/inkwell/sssf.app.yaml` — runtime bun, `bun install`, serve 4501,
  and seven `checks:` entries behavior-identical to the old hardcoded blocks
  (oxlint **1.36.0**, tests timeout 600, `{outdir}` on the four build checks).
- `adws/adw_sssf_config/sssf.meta.config.yaml` — the one-off authorization
  roster itself; builder `writes:` names exactly the nine paths above.

Hard checks:
- `git diff HEAD -- adws/adw_modules/agent_pi.py` is EMPTY and
  `git status --short` shows nothing outside the nine paths. If anything else
  is dirty, stop and report — do not clean it up yourself.

## Step 1 — Host-side verification (no VMs yet)

1. **Loader compat:**
   - `uv run adws/adw_prompt.py --help` works (the new `app:` block parses).
   - A roster WITHOUT the block still loads with compat defaults:
     `uv run python -c "import sys; sys.path.insert(0,'adws'); from adw_modules.agents import load_config; cfg=load_config('adws/adw_sssf_config/sssf.deepestseek.config.yaml'); print(cfg.app.path, cfg.app.manifest)"`
     → `apps/inkwell sssf.app.yaml`. (Check `load_config`'s actual signature
     first; adjust the call, not the module.)
2. **Run-record roundtrip** on a scratch id:
   `sandbox_mount/host/run_record.py create scratch-p01`, `set scratch-p01
   factory_sha=abc123`, `get scratch-p01 factory_sha` → `abc123`; `set
   scratch-p01 bogus=1` still rejected; delete the scratch JSON from
   `.sandbox/runs/`.
3. **Manifest-driven quality smoke:**
   `uv run adws/adw_quality.py "manifest smoke"` from the repo root → all
   **seven** checks pass, driven by `apps/inkwell/sssf.app.yaml`; artifacts
   land under `adws/adw_data/sessions/<id>/context_handoff/quality/` with
   ABSOLUTE `{outdir}` paths; afterwards `git status --short apps/inkwell`
   is EMPTY (the `_check_dir` repo-root anchor keeps build output out of the
   app tree — gate A depends on this).
   Note: this host run uses the DEFAULT roster via `--config` default; the
   meta roster is for this chain's own agents, not for `adw_quality.py`.

## Step 2 — Publish a temp verification branch to origin

Plain `just sbx mount` fills from `origin/main` (`f6eca9e`), which does not
carry the staged work. To verify the NEW quality.py/data_types.py in-sandbox,
the fork must serve them — same mechanism 4c8321b5 used:

1. `git ls-remote origin | grep sssf-verify` — pick a free branch name
   (e.g. `sssf-verify-p01v2`; the old ones are deleted).
2. `git switch -c <branch>`, commit EXACTLY the eight staged paths as one
   temp commit (`git commit` with them staged — do NOT add the meta roster,
   do NOT add anything else), `git push -u origin <branch>`, record
   `TEMP_SHA=$(git rev-parse HEAD)`.
3. Never push `main`. The temp branch is deleted in Step 5.

## Step 3 — Plain `just sbx mount` verification (the letter of the bar)

`just sbx mount sssfp02` (any fresh base id; create adds the date/entropy
suffix). This clones fork main — OLD quality.py — but the host-streamed
provisioner and shipped roster ARE the staged ones. Assert:

- Provision output shows `── 5/9 app ──` with `app apps/inkwell`,
  `manifest sssf.app.yaml`, `install: bun install`; `── 6/9 visualizer ──`
  doing install + `vite build`; `[provision] READY` at the end.
- Gates **A-E all PASS**, gate A printing the new
  `factory  <sha> (matches HEAD)` line (fill recorded `factory_sha`).
- Observe: app lane 200 on the anonymous URL, visualizer lane green.
- `just sbx lifecycle teardown <run-id>` afterwards.

## Step 4 — Pinned run: in-sandbox SDLC + the models.json experiment

This run carries the REAL phase 0/1 code in its clone.

1. `just sbx lifecycle create sssfp02f`
   `just sbx lifecycle fill <id> <TEMP_SHA>`
   `just sbx lifecycle setup <id>` → gates A-E green.
   `just sbx lifecycle observe <id>` → app 200.
2. **Confirm the precondition:** `just sbx run cmd <id> 'ls -la ~/.pi/agent/'`
   → `models.json` ABSENT (fill deletes it).
3. **First execute — expect the known crash:**
   `just sbx lifecycle execute <id> "<one-line inkwell change, e.g. add a footer word-count badge>" "" build-test`
   then `just sbx run cmd <id> 'tail -f run.log'`.
   - EXPECTED: the chain dies with `FileNotFoundError:
     '/home/exedev/.pi/agent/models.json'` from `agent_pi.context_window`.
     Capture the traceback verbatim — this is the empirical proof that
     **models.json-optionality is genuinely required** on fresh boxes.
     It becomes a FINDING in your envelope (name the fill.just:190 deletion,
     the traceback, and the preserved diff
     `/tmp/agent_pi_models_json_optional.patch`). Do NOT re-add the patch.
   - If it instead PASSES unseeded, record that (something recreated
     models.json; optionality would NOT be proven) and skip to step 5.
4. **Seed runtime state and re-run to green** (VM-local state, not a repo
   change, no barred path — it replicates what the old mirror shipped):
   `just sbx run cmd <id> 'mkdir -p ~/.pi/agent && echo "{\"providers\":{}}" > ~/.pi/agent/models.json'`
   Re-run the identical execute command. This time the SDLC completes and
   its quality gate passes manifest-driven: run.log shows
   `quality tests: bun test server.test.ts` run from the app dir,
   `passed: True`, artifacts under
   `/home/exedev/app/adws/adw_data/sessions/<adw>/context_handoff/quality/`,
   and `ADW complete ✓ success`.
5. **Cleanliness:** `just sbx run cmd <id> 'cd app && git status --porcelain'`
   shows ONLY the builder's intended inkwell change (quality artifacts did
   not leak into the app tree).
6. `just sbx lifecycle teardown <id>`.

## Step 5 — Restore staged state, delete the temp branch, land

1. `git push origin --delete <branch>`
2. Restore the exact pre-verification staged state:
   `git switch main && git cherry-pick -n <TEMP_SHA> && git branch -D <branch>`
   (worktree is already identical; this re-stages the eight paths).
3. Land, in three commits (spec commit `9caf426` already exists — verify with
   `git log --oneline -1 -- specs/6159cbd5_any-app-factory-mount.md`, do NOT
   re-commit it):
   - **Phase 0** — `adws/adw_modules/data_types.py`,
     `adws/adw_sssf_config/sssf.config.yaml`,
     `sandbox_mount/host/run_record.py`,
     `just/sandbox/lifecycle/fill.just`, `just/sandbox/lifecycle/setup.just`
     (schema + compat default + factory_sha; zero behavior change).
   - **Phase 1** — `apps/inkwell/sssf.app.yaml`,
     `sandbox_mount/guest/provision.sh`, `adws/adw_modules/quality.py`
     (manifest-driven provision + quality).
   - **Meta roster** — `adws/adw_sssf_config/sssf.meta.config.yaml`
     (the one-off authorization, shipping with the landing it enabled).
4. `git status` must be CLEAN afterwards (untracked session/runtime files
   under `adws/adw_data/` excepted only if already gitignored — check;
   `.sandbox/runs/` scratch record from Step 1 deleted).

## Step 6 — Envelope

- `artifacts`: the nine authorized paths actually committed (drop any you
  never touched).
- **Findings** (this is where the agent_pi question lands):
  - Whether models.json-optionality is genuinely required, with the evidence
    from Step 4 (traceback or its absence), pointing at
    `/tmp/agent_pi_models_json_optional.patch` as the preserved fix. State
    plainly: agent_pi.py was left untouched per the roster; a future
    authorized run should land that diff or an equivalent.
  - Any reconciliation fix-forward from Step 0, with reason.
  - The two verification run-ids and their outcomes (gates, provision shape,
    SDLC quality result).

## Out of scope (respected)

Phases 2-3 (target mode, de-vendoring), `.gitignore` `/target/`, `app.repo`
clone logic, observe/harvest/teardown edits, other roster variants, the
ref-publishing guard (never push `main`), the rollback-index bug, credential
design, any edit to `agent_pi.py`.
