# Plan: accept BOTH `checks:` forms in `quality.py` (map + list)

## Goal (one sentence)

Teach `adws/adw_modules/quality.py::_load_checks` to accept the manifest `checks:`
**map** form that spec `6159cbd5` Decision 2 documents (`key = check name`, `value =
argv list`, defaults `area=backend`, `operation=build`, `timeout_seconds=120`) while
leaving the existing **list** form (`{name, area, operation, argv, timeout_seconds}`,
inkwell's) byte-for-byte behavior-identical, then prove it host-side and on a fresh VM
with hello-server's map-form manifest.

## Context — the divergence, and why only a factory fix counts here

- Spec `6159cbd5` Decision 2 documents:

  ```yaml
  checks:                       # optional: quality-gate commands, run from the app root
    lint:    [bun, x, oxlint@1.15.0, server.ts]
    test:    [bun, test, server.test.ts]
  ```

- `quality.py:84-85` iterates a **list**: `for entry in manifest.get("checks") or []: name = entry["name"]`.
  Iterating a YAML map yields its string keys, so `entry == "test"` and `entry["name"]`
  raises `TypeError: string indices must be integers, not 'str'`.
- Confirmed live, run `1e869019` leg 3 (VM `p3hello2-20261004-8f8b18`, factory `74fba42`,
  target `89b1ae1`): `adw sdlc` aborted at `test_1`, `3/4 phases passed`, `commit` never
  ran, so harvest had nothing to bundle. Artifact:
  `.sandbox/runs/p3hello2-20261004-8f8b18-artifacts/run.log`.
- Two ways out: (1) rewrite hello-server's manifest app-side (rejected — it needs a push
  to an out-of-scope repo, and it would remove the proof that the factory honors its own
  documented schema); (2) normalize the loader (this run). This run is option 2.
- Inkwell's manifest used the list form, so the divergence was invisible until a second
  app arrived. Inkwell's manifest no longer lives in this repo (`apps/` is empty since the
  phase-3 de-vendoring); its 7-entry `checks:` block is reproduced as a fixture in
  Verification A so the "list form unchanged" claim is still tested.

## The change — one insertion, one function, one file

File: `adws/adw_modules/quality.py`. Function: `_load_checks`. Nothing else in the file
changes — no other function, no signature, no module docstring, no `DEFAULT_APP_PATH`.

Current code (lines 84-85):

```python
    specs: list[QualityCheckSpec] = []
    for entry in manifest.get("checks") or []:
```

Replace those two lines with:

```python
    specs: list[QualityCheckSpec] = []
    # `checks:` has TWO documented shapes and BOTH must load:
    #   MAP  — keys are check names, values are argv lists (spec 6159cbd5 Decision 2)
    #   LIST — {name, area, operation, argv, timeout_seconds} mappings (inkwell's)
    # A map entry has nowhere to state area/operation/timeout, so it takes the same
    # defaults a half-filled list entry takes: backend / build / 120 s.
    entries = manifest.get("checks") or []
    if isinstance(entries, dict):
        entries = [{"name": name, "argv": argv} for name, argv in entries.items()]
    for entry in entries:
```

Everything after that is untouched and therefore *shared* by both forms: `entry["argv"]`,
the `{outdir}` → absolute artifact-bundle substitution, the `bun` → `BUN` (`BUN_PATH`)
escape hatch, `entry.get("area", "backend")`, `entry.get("operation", "build")`,
`entry.get("timeout_seconds", 120)`.

Resulting behavior:

| manifest | specs |
|---|---|
| `checks: {test: [bun, test, server.test.ts]}` | `[QualityCheckSpec(name="test", area="backend", operation="build", argv=["bun","test","server.test.ts"], timeout_seconds=120)]` |
| `checks: [{name: tests, ..., timeout_seconds: 600}, ...]` | unchanged from today |
| `checks:` absent / `null` / `{}` | `[]` (no checks → the SDLC still runs plan/build/review) |

Deliberate non-goals (do NOT implement):
- No `area`/`operation`/`timeout_seconds` inside a map value (spec says the value IS the
  argv list). No dict-valued entries, no string-command values (`shlex.split`) — only the
  two documented shapes.
- **Do not change `run_inkwell_tests`' `c.name == "tests"` filter.** It is other
  quality.py behavior and explicitly out of scope. See "Known residual" below — it has a
  direct consequence for how leg (b) must be read, and Verification B compensates with
  evidence instead of code.

Do NOT touch: `hello-server` (its map-form manifest is the proof; changing it invalidates
the leg), `data_types.py`, `provision.sh`, any roster besides this run's, `apps/` (empty),
`.gitignore`, the just recipes.

Leave `adws/adw_sssf_config/sssf.meta4.config.yaml` alone: it is this run's roster and the
chain commits it as the run's record (same precedent as `sssf.meta3.config.yaml`). It needs
no edit for the fix to work.

## Known residual (report it, do not fix it)

`run_inkwell_tests` = "the checks whose **name** is `tests`". hello-server keys its check
`test` (singular), so after the fix the derived spec is named `test` and the `sdlc` lane's
`test_1` phase selects **zero** checks → `QualityResult(passed=True, checks=[])` → the phase
goes green *without ever running the app's test*. `adw plan-build-test` still commits
(because `test.passed` is True), so the leg's pass/fail discriminator is exactly the one the
prompt names: **before the fix `_load_checks` raises `TypeError`; after it the phase is
green and the commit lands.** The check *does* resolve and *does* run under `run_quality`
(the `adw quality` lane / `adw plan-build-test-quality`), which Verification B step B3
exercises directly on the box so the leg is not vacuous evidence. Any widening of the
`tests` filter is a separate, unauthorized change.

## Verification A — host-side: both forms resolve to the identical spec

Scratch only, in `/tmp`. Nothing is written into the repo (in particular
`context_handoff_dir` must be an **absolute /tmp path**, because `_check_dir` mkdirs under
it).

Fixture files: `/tmp/qmap/fake/<case>/target/sssf.app.yaml`; script `/tmp/qmap/forms.py`.

```python
# /tmp/qmap/forms.py — run from the repo root:
#   uv run --quiet --with pydantic --with pyyaml --with python-dotenv python /tmp/qmap/forms.py
import sys, types, pathlib
from pathlib import Path

sys.path.insert(0, "adws")
from adw_modules import quality          # relative imports resolve inside the package

ROOT = Path("/tmp/qmap/fake")
HANDOFF = Path("/tmp/qmap/ctx")          # ABSOLUTE: must not resolve into the repo

# One logical check, written both ways. Same NAME in both, else they are not the
# same check: the map key IS the name ("test" != "tests").
LIST_FORM = """
checks:
  - name: tests
    area: backend
    operation: build
    argv: [bun, test, server.test.ts]
    timeout_seconds: 120
"""
MAP_FORM = """
checks:
  tests: [bun, test, server.test.ts]
"""

INKWELL_LIST = """            # inkwell's 7 checks, verbatim shape (apps/inkwell is gone from
checks:                       # the factory; from .sandbox/runs/p2verify-*/target/sssf.app.yaml)
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
    operation: build
    argv: [bun, test, server.test.ts]
    timeout_seconds: 600
"""

def stub(case: str, body: str):
    """The minimum `run` shape _load_checks touches. NOTE: repo_root and
    context_handoff_dir must be pathlib.Paths (quality._app_dir / _check_dir join
    them), and phases[-1].seq must exist."""
    d = ROOT / case
    (d / "target").mkdir(parents=True, exist_ok=True)
    (d / "target" / "sssf.app.yaml").write_text(body)
    cfg = types.SimpleNamespace(app=types.SimpleNamespace(path="target",
                                                          manifest="sssf.app.yaml"))
    return types.SimpleNamespace(cfg=cfg, repo_root=d, context_handoff_dir=HANDOFF,
                                 phases=[types.SimpleNamespace(seq=1)])

def load(case, body):
    return quality._load_checks(stub(case, body))

list_specs = load("list", LIST_FORM)
map_specs  = load("map", MAP_FORM)
assert list_specs == map_specs, (list_specs, map_specs)          # ordered, exact
assert {s.name: s for s in list_specs} == {s.name: s for s in map_specs}
assert map_specs == [quality.QualityCheckSpec(name="tests", area="backend",
                                              operation="build",
                                              argv=["bun", "test", "server.test.ts"],
                                              timeout_seconds=120)]

ink = load("inkwell", INKWELL_LIST)                              # list form unchanged
assert [s.name for s in ink] == ["frontend_lint", "backend_lint", "frontend_typecheck",
                                 "backend_typecheck", "frontend_build", "backend_build", "tests"]
assert ink[-1].timeout_seconds == 600 and ink[0].area == "frontend"
assert ink[-1].argv == ["bun", "test", "server.test.ts"]
assert ink[2].argv[-1] == str(HANDOFF / "quality" / "01_frontend_typecheck" / "bundle")

for body in ("", "checks:\n", "checks: {}\n"):                   # no checks → []
    assert load("empty" + str(len(body)), body) == []

print("A PASS: map == list (identical QualityCheckSpec); inkwell list form unchanged; empty → []")
```

**Negative control (run it first, it is free):** with the *unpatched* file this harness
raises `TypeError: string indices must be integers, not 'str'` at `quality.py:85` — the very
crash from leg 3. Re-running it after the edit must print `A PASS`. (Verified this session:
unpatched → crash at line 85; with the two-line change above → `A PASS`.)

## Verification B — fresh VM, the exact leg that crashed

Preconditions on the host: `.env` with the provider keys (gates C/E), the exe.dev account
reachable, `bun`/`just`/`uv` on PATH. Sanity-check the target ref and that the map form is
still what hello-server ships:

```bash
git ls-remote https://github.com/yhuangsh/hello-server.git main   # expect 89b1ae17...
```

**B1 — mount a fresh VM with the hello roster (must be a NEW run id; the old VM is dead):**

```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount qmapfix
```

Capture the resolved `RUN_ID` from the printed `mounted: <id>` line (the recipe appends
`-<date>-<6 hex>`). Expected: **gates A–E green** (A factory `74fba42`-or-later ==
`factory_sha` + factory tree clean + target `89b1ae1` == `commit_sha`; B pi version parity;
C every roster provider answers through pi; D cost sanity; E 4/4 provider keys) and the
observe lane reporting the app 200 anonymous on `:4501`.
If gate C fails on `kimi-coding/k3` with a `403 … 5-hour usage limit` (Finding B in
`1e869019`'s report) that is a transient provider window, not a defect: wait for the window
and mount again. Never edit the roster to work around it.

**B2 — get the FIXED loader onto the box (the one step that needs explaining).**

FILL clones the factory from `origin/main` (`74fba42`), so a fresh VM cannot contain an
uncommitted local fix — and this run must neither commit nor push (the chain's commit phase
owns commits; pushing is out of scope). Therefore the leg is run with the host's exact bytes
transferred to the box, byte-verified:

```bash
VM=$(python3 sandbox_mount/host/run_record.py get <RUN_ID> vm_name)

# the fix, host -> box
ssh "$VM".exe.xyz 'cat > /home/exedev/app/adws/adw_modules/quality.py' \
    < adws/adw_modules/quality.py

# byte identity, both sides (must print the same digest)
sha256sum adws/adw_modules/quality.py
ssh "$VM".exe.xyz 'sha256sum /home/exedev/app/adws/adw_modules/quality.py'

# the box's only working-tree change is exactly this file
ssh "$VM".exe.xyz 'cd app && git diff --stat'
```

Expected: identical sha256; `git diff --stat` names exactly `adws/adw_modules/quality.py`,
1 file changed. (Optional stronger check: `git -C app diff | sha256sum` on the box equals
`git diff -- adws/adw_modules/quality.py | sha256sum` on the host.) This is evidence, not a
shortcut: the leg below then executes *the host's bytes* for the function that crashed, and
the host-side Verification A already proved those bytes behave for both forms. Once the
chain lands (and the operator publishes `origin/main`), a later fresh mount needs no
transfer at all.

**B3 — prove the map-form check actually resolves AND runs (in-sandbox, synchronous).**
The `sdlc` lane only runs checks *named* `tests`, and hello-server's key is `test`, so B4
alone would pass with `0/0 checks`. `adw quality` runs **every** manifest check
(`quality.run_quality`), which is the direct in-sandbox proof:

```bash
just sbx run cmd <RUN_ID> 'just --shell bash --shell-arg -c adw quality mapform-smoke --config /home/exedev/sssf_config.yaml'
```

Expected: one check reported as `quality test: bun test server.test.ts` → `passed (exit 0)`,
phase `quality` ✓, exit status 0. Capture: the check name, the command string, the exit
code, and the `command.log` artifact path (`adws/adw_data/.../context_handoff/quality/…/`).
That is the app's own declared check running under the map form — impossible before the fix.

**B4 — the crashed leg itself: one-line SDLC through the execute lane (detached).**

```bash
just sbx lifecycle execute <RUN_ID> 'In target/, add a GET /health endpoint to server.ts that returns {"ok":true} and keep the existing bun test passing'
```

(no `CONFIG` argument → the shipped `/home/exedev/sssf_config.yaml` = the hello roster; no
`ADW` argument → `sdlc` = `adw_plan_build_test.py`, the exact workflow whose `test_1` phase
crashed). Poll:

```bash
just sbx run cmd <RUN_ID> 'tail -n 40 run.log'
```

Expected, and this is the accept criterion: the phase table reads
`status ✓ success`, `phases 5/5 passed` (`request`, `plan`, `build`, `test_1`, `commit`),
**no traceback, no `string indices must be integers`**, and the `commit` phase logs a sha.
Before the fix this same command produced `3/4 phases passed` + `TypeError` at
`quality.py:85` and no commit (see `p3hello2-…-artifacts/run.log`).

**B5 — confirm the effect that leg 4 depends on (no harvest, no ref writes):**

```bash
just sbx run cmd <RUN_ID> 'cd target && git log --oneline -3 && git status --porcelain'
```

Expected: a new commit on `sbx/<RUN_ID>` on top of `89b1ae1`, clean worktree. Do **not** run
`just sbx manage harvest` (it writes `refs/sandbox/<id>` — a ref mutation the standing rule
forbids, and this run's done-condition does not include leg 4).

**B6 — close the box (recommended, matches leg 5 of the previous run):**

```bash
just sbx lifecycle teardown <RUN_ID>
```

Pulls `specs/ app_docs/ adws/ run.log target/sssf.app.yaml` into
`.sandbox/runs/<RUN_ID>-artifacts/`, destroys the VM, closes the record. If the operator
wants to poke at the box, leaving it mounted is fine — but record the run id and the
evidence paths either way.

**Evidence to put in the builder envelope:** VM run id + `factory_sha`/`commit_sha` from its
record; host and box sha256 of `quality.py`; the `adw quality` check name/command/exit line;
the `phases 5/5 passed` line and the commit sha from `run.log`; `git log -1` on the box.

## Why this chain still reaches its commit phase

`sssf.meta4.config.yaml` is intentionally vendored-mode (`app.path: apps/inkwell`, no
`repo:`), and `apps/` is empty since the phase-3 de-vendoring — so `payload_root` → factory
root and the host-side `test` phase finds no manifest → `_load_checks` returns `[]` →
`QualityResult(passed=True)` → the `commit` phase runs. That trivial pass is expected; the
real proof of this change is Verification A plus the fresh-VM leg B.

## Deliverables / rules

- Modify only `adws/adw_modules/quality.py` (insertion above). Leave
  `adws/adw_sssf_config/sssf.meta4.config.yaml` untouched.
- `changed_files` = `["adws/adw_modules/quality.py"]` (list only paths that exist after the
  change; do not list `apps/inkwell/sssf.app.yaml`, which no longer exists).
- **No** `git commit`, `git push`, `git checkout`, `git branch`, `git reset`, or any ref
  mutation; no harvest. Leave the tree dirty for the chain's commit phase; `git add` is
  allowed but unnecessary.
- All scratch (the Verification A harness, manifests, logs) lives under `/tmp`. No stray
  files, no `*.log`/`out.txt` in the repo — the only host-tree deltas are the intended edit,
  the untracked run roster, and the planner's spec file.
- Report a failed and a passed leg honestly: if the VM leg cannot run (exa/kimi/provider
  outage, no exe.dev account), say so explicitly and hand over the exact command list — do
  not claim leg B green without the `phases 5/5 passed` line.

## Risks / rollback

- **kimi 5-hour quota** (Finding B): gate C is a hard stop for a mount; retry after the
  window. Never patch the roster to dodge it.
- **`test_1` runs zero checks for a check named `test`** (Known residual): B4's green is a
  no-crash proof, B3's `adw quality` run is the "the map check really runs" proof. Do not
  silently claim B4 proved the suite ran.
- **B2 transfer skipped or mis-targeted**: then B4 reproduces `TypeError` — which is itself
  the negative control confirming the leg is sensitive to the fix. Re-transfer and re-run
  (the SDLC lane truncates `run.log` on each execute).
- **Rollback**: the change is a two-line insertion inside one function; reverting the two
  lines restores today's behavior exactly. No schema, data, or on-box state is touched.
