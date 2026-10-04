# Plan: Implement Phases 0 and 1 of the any-app factory-mount spec

## Authoritative spec

`specs/6159cbd5_any-app-factory-mount.md` (byte-identical copy:
`adws/adw_data/sessions/6159cbd5/context_handoff/plan.md`) is the spec. It is
authoritative for every touchpoint — fill/setup/observe/teardown justs,
`sandbox_mount/guest/provision.sh`, `adws/adw_modules/quality.py`,
`adws/adw_sssf_config/sssf.config.yaml`, `sandbox_mount/host/run_record.py`.
Read it first. This plan scopes it to **Phase 0 and Phase 1 only** and pins
down the details the spec leaves to build time.

**First commit:** the spec file is already in the working tree but untracked
(`git status` shows `?? specs/6159cbd5_any-app-factory-mount.md`). Land it as
its own "spec" commit before any code change. Do not edit its content.

## Scope

- **Phase 0** — schema + compat default: `app:` block in `sssf.config.yaml`
  resolving to `apps/inkwell`; `factory_sha` field in the run record, recorded
  by fill; behavior byte-identical to today.
- **Phase 1** — `apps/inkwell/sssf.app.yaml` expressing exactly today's
  behavior; `provision.sh` steps 5–8 rewritten as the generic manifest-driven
  app step; `adws/adw_modules/quality.py` manifest-driven with inkwell's
  checks re-expressed behavior-identically.
- **Out of scope:** Phases 2–3 (target mode, de-vendoring), `.gitignore`
  changes (that lands with Phase 2 — do NOT add `/target/`), the
  ref-publishing guard, multi-app-per-VM, credential design, observe.just /
  harvest.just / teardown.just changes (their generalization is Phase 2+;
  hardcoded inkwell paths there still pass because Phase 0/1 resolve to
  `apps/inkwell`).

## Recon facts (verified this session — trust these)

- `run_record.py` has a **closed schema**: `FIELDS` tuple; `set` rejects
  unknown keys. Adding `factory_sha` to `FIELDS` is the whole change (the spec
  sanctions exactly this one extension). Old records lack the key; `get`
  returns `None` → printed as empty string. `_COERCE` needs no entry (it's a
  plain string).
- `fill.just` records the clone HEAD at line ~137:
  `"$RR" set {{RUN_ID}} commit_sha="$HEAD_SHA"` (right after the pin gate).
- `setup.just` gate A reads `commit_sha` from the record (line ~39) and
  compares against the VM's HEAD.
- `SSSFConfig` (`adws/adw_modules/data_types.py` line ~346) is a pydantic
  model: `defaults`, `observability`, `agents`. Pydantic v2 ignores unknown
  YAML keys, but `load_config` (`agents.py` line ~33) does
  `SSSFConfig(**raw)` — add a proper `AppConfig` model rather than relying on
  ignore-extra.
- `quality.py` today: `BUN` escape hatch (`BUN_PATH` env, default `bun`),
  `_check_dir(run, name)` → `<context_handoff>/quality/NN_<name>`,
  `_run(spec, run)` runs `spec.argv` with `cwd=run.repo_root`, default timeout
  120 s (`QualityCheckSpec.timeout_seconds`). Seven hardcoded checks:
  `frontend_lint`, `backend_lint` (oxlint **1.36.0** — the `OXLINT_VERSION`
  constant, NOT the 1.15.0 in the spec's illustrative example),
  `frontend_typecheck`, `backend_typecheck`, `frontend_build`,
  `backend_build` (the four with a dynamic `--outdir <check_dir>/bundle`),
  and `tests` (`bun test apps/inkwell/server.test.ts`, timeout 600).
- **Callers of quality.py** (keep these working, signatures unchanged):
  - `adw_simple_sdlc.py`, `adw_plan_build_test.py`, `adw_build_test.py` →
    `quality.run_inkwell_tests(run)`
  - `adw_quality.py` (line 33) and `adw_plan_build_test_quality.py` (line 58)
    → `quality.run_quality(run)` — **this function does not exist today**
    (verified: `hasattr(quality, 'run_quality')` is False; both callers are
    latently broken). A comment in `adw_plan_build_test_quality.py` states the
    intended semantics: "run_quality() already includes the test block".
    Phase 1's rewrite defines `run_quality` and fixes both callers.
- `provision.sh` is host-streamed into the VM (run 9466f202), so it evolves
  freely. Steps: 1 repo root, 2 bun, 3 just, 4 node/pi, 5 `bun install` over
  `apps/inkwell` + `.claude/skills/sssf/apps/visualizer`, 6 visualizer
  `bunx vite build`, 7 trace-db DDL via a `uv run` PEP-723 heredoc (pyyaml
  already among its deps), 8 warm uv cache, 9 summary. `uv` ships in the
  exeuntu image. NEVER apt.
- The roster is shipped verbatim by fill to `/home/exedev/sssf_config.yaml`
  (fill.just line ~162); the host-side roster path is
  `${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}`.
- Only `adws/adw_sssf_config/sssf.config.yaml` gets the `app:` block. The
  other roster variants (deepestseek, frontier, open-weights, top-speed) stay
  untouched — the loader default covers their absence.
- `observe.just` (lines ~36–38) hardcodes `APP_DIR=$HOME/app/apps/inkwell`,
  port 4501 — unchanged this phase; it keeps passing because the app dir
  resolves to `apps/inkwell`.

## Phase 0 — schema + compat default (zero behavior change)

1. **`adws/adw_modules/data_types.py`** — add:
   ```python
   class AppConfig(BaseModel):
       # Phase 0 compat defaults: payload vendored in the factory clone.
       # repo=None means "no separate target clone" (Phase 2 introduces it).
       repo: Optional[str] = None
       ref: Optional[str] = None
       path: str = "apps/inkwell"
       manifest: str = "sssf.app.yaml"     # relative to <path>
   ```
   and on `SSSFConfig`: `app: AppConfig = Field(default_factory=AppConfig)`.
   Absent block → compat default, so every existing roster keeps working.
2. **`adws/adw_sssf_config/sssf.config.yaml`** — add a top-level block
   (with a short comment naming it the per-app input per the spec, Phase 0
   compat values):
   ```yaml
   app:
     # repo: <not set — payload is vendored at apps/inkwell (Phase 0/1)>
     path: apps/inkwell
     manifest: sssf.app.yaml
   ```
3. **`sandbox_mount/host/run_record.py`** — add `"factory_sha"` to `FIELDS`
   (any position; keep `IMMUTABLE` and `_COERCE` unchanged). Nothing else —
   `create` seeds it None, `get`/`set` handle it automatically.
4. **`just/sandbox/lifecycle/fill.just`** — immediately after the existing
   `commit_sha` set (~line 137), record the same HEAD:
   `"$RR" set {{RUN_ID}} factory_sha="$HEAD_SHA"`. One line; in Phase 0 the
   factory clone is the only clone, so `factory_sha == commit_sha` by
   construction. (Phase 2 will point `commit_sha` at the target clone.)
5. **`just/sandbox/lifecycle/setup.just`** gate A — after the existing
   HEAD-vs-`commit_sha` assertion, add a null-tolerant assertion that factory
   HEAD == `factory_sha` when the record has one (records predating this
   change have it null → skip). Per the spec: "gate A compares it against the
   same HEAD" — outcome byte-identical today.

**Phase 0 verification (zero-behavior-change bar):**
- `uv run adws/adw_prompt.py --help` still works (loader accepts the new
  block; also confirm a variant roster without the block still loads:
  `uv run python -c` load of `sssf.deepestseek.config.yaml` →
  `cfg.app.path == "apps/inkwell"`).
- Run-record roundtrip on a scratch id: `create`, `set factory_sha=abc123`,
  `get factory_sha` → `abc123`; `set bogus=1` still rejected; clean up the
  scratch record from `.sandbox/runs/`.
- Real mount: `just sbx mount <fresh-id>` on inkwell — gates A–E green,
  observe returns 200 on the app lane, provision output unchanged in
  structure (still today's steps). Tear the VM down afterwards.

## Phase 1 — manifest-driven provision + quality

### 1. `apps/inkwell/sssf.app.yaml` (new file) — exactly today's behavior

```yaml
# sssf.app.yaml — what inkwell needs from a blank exeuntu VM.
runtime: bun
install:
  - bun install
build: []
serve:
  command: bun run server.ts
  port: 4501
  health_path: /
checks:
  # argv paths are relative to the app dir (checks run with cwd = app dir).
  # {outdir} is substituted by quality.py with the check's absolute artifact
  # bundle dir (<context_handoff>/quality/NN_<name>/bundle).
  - name: frontend_lint
    area: frontend
    operation: lint
    argv: [bun, x, oxlint@1.36.0, public/app.js]
  - name: backend_lint
    area: backend
    operation: lint
    argv: [bun, x, oxlint@1.36.0, server.ts]
  - name: frontend_typecheck
    area: frontend
    operation: typecheck
    argv: [bun, build, --target=browser, public/app.js, --outdir, "{outdir}"]
  - name: backend_typecheck
    area: backend
    operation: typecheck
    argv: [bun, build, --target=bun, server.ts, --outdir, "{outdir}"]
  - name: frontend_build
    area: frontend
    operation: build
    argv: [bun, build, --target=browser, --minify, public/app.js, --outdir, "{outdir}"]
  - name: backend_build
    area: backend
    operation: build
    argv: [bun, build, --target=bun, --minify, server.ts, --outdir, "{outdir}"]
  - name: tests
    area: backend
    operation: build           # the QualityOperation enum has no "test"; the name carries it
    argv: [bun, test, server.test.ts]
    timeout_seconds: 600
```

### 2. `sandbox_mount/guest/provision.sh` — steps 5–8 rewritten

Steps 1–4 and the summary/sentinel stay byte-for-byte. New middle:

- **Step 5 — `app` (generic, manifest-driven).** One parser, per the spec: a
  `uv run` PEP-723 heredoc (same pattern as the trace-db step; pyyaml is
  already a tracer dependency — no new binary). It reads `app.path` (default
  `apps/inkwell`) and `app.manifest` (default `sssf.app.yaml`) from
  `/home/exedev/sssf_config.yaml`, then reads the manifest at
  `$REPO_ROOT/<path>/<manifest>` if present. Have the script emit the parsed
  values in a shell-consumable form (e.g. key=value lines or JSON read back
  with `uv run` once more — builder's choice, but ONE parsing mechanism).
  Then, in bash:
  1. `APP_DIR="$REPO_ROOT/<path>"`; if the dir is absent, fail fast with a
     named error.
  2. **Runtime:** declared `runtime` must already be on PATH — `bun`/`node`
     from steps 2/4, `uv` from the image. Anything else: fail fast naming the
     runtime; NEVER apt.
  3. **install, then build:** each declared command run as
     `( cd "$APP_DIR" && <cmd> )` under the step banner, so the ERR trap names
     the stage. Echo each command before running it.
  4. **Fallbacks:** no manifest file → if `$APP_DIR/package.json` exists run
     `bun install` there, else `say "skipped <path> (no manifest, no package.json)"`.
     Manifest present but key absent → skip that part with a `say` line,
     never a failure (mirrors today's `skipped (no package.json)`).
- **Step 6 — visualizer (factory runtime, absorbs its install).** The
  visualizer's `bun install` moves here from old step 5 (it is factory
  machinery, not app payload): install if `package.json` present, then
  `bunx vite build` exactly as today, same skip-if-absent behavior.
- **Step 7 — trace db.** Unchanged.
- **Step 8 — warm uv.** Unchanged. (The step-5 YAML probe may pay the cold
  PEP-723 resolve earlier; that is fine and step 8 stays as the assertion.)
- Keep the `N/9` numbering scheme coherent (still 9 steps) and keep
  `touch /tmp/PROVISION_READY` as the literal last line.

### 3. `adws/adw_modules/quality.py` — manifest-driven check set

Keep `_check_dir`, `_run`, the `BUN`/`BUN_PATH` escape hatch, `TAIL_CHARS`,
and `as_envelope` as they are. Replace the seven hardcoded check functions
with a manifest loader plus thin entry points:

- `_load_checks(run) -> list[QualityCheckSpec]`: app dir =
  `run.repo_root / cfg.app.path` (cfg from the run's config; fall back to the
  `AppConfig` defaults if the run carries none), manifest =
  `cfg.app.manifest` under the app dir, parsed with `yaml.safe_load`
  (pyyaml is already an ADW dependency — the sandbox-side PEP-723 constraint
  does not apply here). For each entry: substitute the literal token
  `{outdir}` in argv elements with `str(_check_dir(run, name) / "bundle")`;
  if `argv[0] == "bun"` replace it with `BUN` (preserves the escape hatch);
  default `timeout_seconds` stays 120 from `QualityCheckSpec`. Run checks with
  `cwd` = the app dir — extend `_run` minimally for a per-spec cwd (default
  `run.repo_root`) rather than duplicating it.
  - Manifest absent or no `checks:` → per the spec, the default is the
    manifest's `checks.test` if present, else **no checks** (a `run_quality`
    with zero checks returns `passed=True` with an empty list and logs a
    line saying so; the SDLC still runs plan/build/review).
- Public API (all existing callers keep working):
  - `run_quality(run)` — **new**, runs ALL manifest checks (the six blocks +
    `tests`), collecting failures exactly like today's `run_inkwell_quality`.
    This fixes the latently broken `adw_quality.py` /
    `adw_plan_build_test_quality.py` callers and matches the documented
    intent ("run_quality() already includes the test block").
  - `run_inkwell_quality(run)` — kept; runs the manifest checks excluding the
    one named `tests`. Behavior-identical to today for inkwell.
  - `run_inkwell_tests(run)` — kept; runs only the check named `tests`,
    wrapped as a single-check `QualityResult` exactly as today.
- Do not touch `agents.py`, `permissions.py`, the tracer, or any `adw_*.py`
  caller.

**Phase 1 verification:**
- Host-side, before any sandbox: `uv run adws/adw_quality.py "manifest smoke"`
  from the repo root — all seven checks pass, driven by
  `apps/inkwell/sssf.app.yaml` (artifacts land under
  `adws/adw_data/sessions/<id>/quality/`). Also
  `uv run adws/adw_plan_build_test_quality.py` is out of scope to run fully
  (agent chain), but `python -c "from adw_modules import quality;
  quality.run_quality"` resolving is covered by the smoke run.
- **Fresh real mount:** `just sbx mount <fresh-id>` on inkwell —
  - provision output shows the new `── 5/9 app ──` step reading
    `sssf.app.yaml` and running `bun install` from `apps/inkwell`, the
    visualizer step doing install+build, and `[provision] READY`;
  - gates A–E green (including the new null-tolerant `factory_sha`
    assertion);
  - observe: app lane 200 on `https://<vm>.exe.xyz/` (hardcoded inkwell path
    still correct), visualizer lane green.
- **Small in-sandbox SDLC (execute lane):** on the mounted run, execute a
  one-line change through the execute lane (e.g.
  `just sbx lifecycle execute <run-id> "<tiny inkwell change>" "" <chain>`
  using a chain whose test phase calls `run_inkwell_tests` — e.g. the
  simple-SDLC/build-test chain used by previous sandbox runs) and confirm its
  quality gate passes with the manifest-driven `bun test
  apps/inkwell/server.test.ts` equivalent.
- Tear down the run (`just sbx lifecycle teardown <run-id>`) when done.

## Commits

1. Spec commit: `specs/6159cbd5_any-app-factory-mount.md` (content unchanged).
2. Phase 0 commit(s): config schema + `factory_sha` + fill/setup lines —
   verifiably zero-behavior-change.
3. Phase 1 commit(s): inkwell manifest + provision.sh app step + quality.py.

Each phase independently green per the spec's migration rule: a failure in
Phase 1 leaves Phase 0 as the working system.

## Explicitly NOT in this change

- No `.gitignore` edit (`/target/` is Phase 2).
- No `app.repo`/`ref` clone logic in fill (Phase 2 target mode).
- No observe.just / harvest.just / teardown.just edits.
- No changes to the other roster variants.
- No `target/` directory, no de-vendoring of `apps/inkwell`.
