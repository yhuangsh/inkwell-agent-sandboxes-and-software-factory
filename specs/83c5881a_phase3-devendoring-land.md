# Plan: land phase 3 de-vendoring (payload_root fallback + hello roster + inkwell removal)

Parent spec: `specs/8afdf5ba_phase3-devendoring-payload-fix.md` (attempt 8afdf5ba did the
work but died at the gate) — this plan is the resume, plus one newly discovered blocker
(Task 6b) that the earlier plan missed.

## The one-line version

Almost all of this work is already in the working tree and verified correct. The
builder's job is **verify, finalize the hello roster with one honest caveat comment,
`git add` the authorized paths, and write a truthful envelope + blocked report** — not
to redo it. Nothing here is committed by an agent: this chain's single `commit` phase
(`git add -A` + `git commit`) lands everything.

## Hard constraints (operator, apply to the builder)

- **Do NOT run** `git commit`, `git push`, `git checkout`, `git branch`, `git reset`, or
  any ref mutation. `git add` IS allowed. Leave the tree dirty; the chain's commit phase
  owns the commit.
- **Envelope rule (this is what killed attempt 8afdf5ba):** `changed_files` may list
  **ONLY paths that exist on disk after your change**. `gates.diff_matches_claims` checks
  every claimed path with `Path(f).exists()` — a deleted path claimed there fails the
  phase. `apps/inkwell/` is *deleted*, so **never** list it (nor any `apps/inkwell/*`)
  in `changed_files`. Put the deletion in `summary` / `notes_for_next_agent` as text.
- **Authorized repo paths — exactly these, nothing else:**
  - `adws/adw_modules/git_helper.py`
  - `adws/adw_sssf_config/sssf.config.yaml`
  - `adws/adw_sssf_config/sssf.hello.config.yaml`
  - `adws/adw_sssf_config/sssf.meta3.config.yaml`
  - `apps/inkwell/` (deletion)
  `permissions.py` enforces this after the phase; anything else (notably
  `adws/adw_modules/quality.py`, `adws/adw_modules/data_types.py`, `TREE.md`,
  `just/inkwell.just`, `sandbox_mount/guest/provision.sh`) is **protected or
  unlisted and will be rolled back**, aborting the phase. Do not "helpfully" fix the
  stale references listed in Task 4b.
- **`specs/` is not yours.** The planner's spec file lives there and the commit phase
  stages it. Do not create, edit, or delete anything under `specs/`.
- **Scratch output to `/tmp`, never into the repo.** Do not leave a `target/` clone in
  the factory root (see Task 1).
- Do NOT push anything to any remote. The fresh-VM legs are BLOCK-REPORTED (Task 6).

## State verified this session (all facts below were checked, not assumed)

- `git status --porcelain` is exactly:
  `M adws/adw_modules/git_helper.py`, `M adws/adw_sssf_config/sssf.config.yaml`,
  `M adws/adw_sssf_config/sssf.meta3.config.yaml`, eight `D apps/inkwell/…` entries
  (`README.md`, `package.json`, `public/app.js`, `public/index.html`,
  `public/style.css`, `server.test.ts`, `server.ts`, `sssf.app.yaml`,
  `validation.png`), `?? adws/adw_sssf_config/sssf.hello.config.yaml`. Nothing else.
- `adws/adw_modules/git_helper.py::payload_root` already carries the fix
  (`target.is_dir() and is_repo(target)` short-circuit, then factory-root fallback).
  **I ran the three-mode harness against it — all three modes pass** (Task 1 has the
  known-good script).
- `sssf.config.yaml`'s diff is comment-only and **accurate**: it replaced
  "`apps/inkwell` stays vendored until Phase 3 and is simply unused here" with
  "Phase 3 de-vendored: no app code lives in the factory clone (inkwell's history is at
  https://github.com/yhuangsh/inkwell.git)". Keep it. The default roster's `app:` block
  was already target-mode (`repo: …/inkwell.git`, `path: target`) — no functional change.
- `sssf.meta3.config.yaml` differs from its committed form only in the planner `model`
  line (`kimi-coding/k3` → `deepseek/deepseek-flash`, with a comment naming the 403
  quota block). That is the operator's run-roster edit. **Leave its content exactly as
  is**; it is this chain's run config and is deleted in the follow-up run, not here.
- `adws/adw_sssf_config/sssf.hello.config.yaml` already exists (untracked, written by
  attempt 8afdf5ba) and **already satisfies the ask**: it loads via
  `agents.load_config` with 5 agents, `app.repo =
  https://github.com/yhuangsh/hello-server.git`, `path: target`, `ref: main`,
  `manifest: sssf.app.yaml`, and the only hunks vs `sssf.config.yaml` are the header
  comment and the `app:` block.
- `https://github.com/yhuangsh/hello-server.git` is public; `git ls-remote` gives
  `main = 89b1ae17dbf7b0d48c9200cabc11333a26faf56d`. At that sha the repo contains
  `package.json`, `server.ts`, `server.test.ts`, `sssf.app.yaml` (verified via the
  GitHub trees API).

## Task 1 — verify the `payload_root` fix handles both modes (and the non-git edge)

No code change needed — `git_helper.py` already holds the fix. Re-run the harness so the
envelope has first-hand evidence. It runs from the factory root and clones ONLY into
`/tmp`, so the repo never sees a `target/` (and the tree stays exactly as listed above):

```bash
uv run --with pydantic --with pyyaml python - <<'EOF'
import subprocess, sys
sys.path.insert(0, "adws")
from pathlib import Path
from adw_modules.data_types import AppConfig
from adw_modules import git_helper

root = Path.cwd()
t = AppConfig(repo="https://github.com/yhuangsh/hello-server.git", path="target")

# Mode 1 — vendored (no repo): factory root, byte-identical to the old behavior.
assert git_helper.payload_root(AppConfig(path="apps/inkwell"), root) == root.resolve()

# Mode 2 — target mode, NO clone on the host: must fall back, not crash.
assert not (root / "target").exists()
assert git_helper.payload_root(t, root) == root.resolve()
git_helper.rev("HEAD", repo=git_helper.payload_root(t, root))   # used to raise FileNotFoundError

# Mode 2b — a directory exists at <root>/<path> but is NOT a git repo: fall back, no crash.
notgit = Path("/tmp/sssf-payload-check/notgit")
subprocess.run(["rm", "-rf", str(notgit)], check=True)
(notgit / "target").mkdir(parents=True, exist_ok=True)
assert git_helper.payload_root(t, notgit) == notgit.resolve()

# Mode 3 — in-VM layout: a checked-out clone at <factory>/<path> is the payload root.
scratch = Path("/tmp/sssf-payload-check/fakeroot")
subprocess.run(["rm", "-rf", str(scratch)], check=True)
scratch.mkdir(parents=True)
subprocess.run(["git", "clone", "-q",
                "https://github.com/yhuangsh/hello-server.git", "target"],
               cwd=scratch, check=True)
assert git_helper.payload_root(t, scratch) == (scratch / "target").resolve()

print("payload_root: all modes OK")
EOF
```

Exit status 0 is the verdict. The short-circuit order matters: `is_repo()` runs
`git rev-parse --git-dir` with `cwd=target`, so `target.is_dir()` MUST be tested first —
that ordering IS the fix.

## Task 2 — review the `sssf.config.yaml` comment diff

Already reviewed above: the comment is accurate after de-vendoring. **Keep it; change
nothing.** (The builder should confirm the diff is comment-only, e.g.
`git diff -- adws/adw_sssf_config/sssf.config.yaml` shows only the two comment lines.)

## Task 3 — finalize `adws/adw_sssf_config/sssf.hello.config.yaml`

The file exists and is correct. Two things to do:

### 3a. Prove "only the `app:` block differs" by parsing, not by eyeballing

```bash
uv run --with pydantic --with pyyaml --with python-dotenv --with rich python - <<'EOF'
import sys, yaml
sys.path.insert(0, "adws")
from pathlib import Path
from adw_modules import agents

a = yaml.safe_load(Path("adws/adw_sssf_config/sssf.config.yaml").read_text())
b = yaml.safe_load(Path("adws/adw_sssf_config/sssf.hello.config.yaml").read_text())
# Everything except `app` is identical — that identity IS the proof.
assert {k: v for k, v in a.items() if k != "app"} == {k: v for k, v in b.items() if k != "app"}
assert a["app"] == {"repo": "https://github.com/yhuangsh/inkwell.git", "ref": "main",
                    "path": "target", "manifest": "sssf.app.yaml"}
assert b["app"] == {"repo": "https://github.com/yhuangsh/hello-server.git", "ref": "main",
                    "path": "target", "manifest": "sssf.app.yaml"}

cfg = agents.load_config(Path("adws/adw_sssf_config/sssf.hello.config.yaml"))
assert [ag.name for ag in cfg.agents] == ["planner", "builder", "scout", "reviewer", "documenter"]
assert cfg.app.repo.endswith("hello-server.git")
print("hello roster: identical to default except app:, loads with 5 agents")
EOF
```

Exit status 0 is the verdict.

### 3b. Add the one caveat comment the earlier plan missed (see Task 6b)

`hello-server`'s manifest declares `checks:` in the **compact map** form
(`{test: [bun, test, server.test.ts]}`), but `quality._load_checks` iterates a **list**
of `{name, area, operation, argv}` mappings and calls `entry["name"]` — the map raises
`TypeError: string indices must be integers`. I reproduced this against the real loader
(Task 6b). The toy-app leg's "manifest-driven quality gate" cannot pass until that is
resolved, so record it in the committed roster rather than only in a gitignored report.

Edit ONLY the `manifest:` comment lines of the `app:` block in
`sssf.hello.config.yaml`, so the block reads:

```yaml
  path: target
  manifest: sssf.app.yaml   # carried by the app repo: bun runtime, install,
                            # serve `bun run server.ts` on 4501, checks.test
                            #
                            # CAVEAT — the toy-app VM leg must fix this first.
                            # hello-server declares `checks:` as the compact map
                            # {test: [bun, test, server.test.ts]}; quality._load_checks
                            # iterates a LIST of {name, area, operation, argv}, so the
                            # map raises TypeError ("string indices must be integers")
                            # and aborts the in-sandbox SDLC's test phase. Resolve
                            # app-side (rewrite checks to the list form; keeps "zero
                            # factory code edits" true) or normalize quality.py in a
                            # separately authorized run. Verified in session 83c5881a;
                            # see its context_handoff/blocked_report.md.
```

No YAML value changes — comments only. Re-run 3a's script after editing (the parsed
comparison must still pass; comment edits cannot move it, which is the point).

## Task 4 — confirm `apps/inkwell/` removal is complete

### 4a. Prove it

```bash
test ! -d apps/inkwell && test -z "$(find apps -mindepth 1 2>/dev/null)" \
  && git status --porcelain | grep -c '^ D apps/inkwell/' | grep -qx 9 \
  && echo "apps/inkwell fully removed (9 tracked deletions, no leftovers)"
```

Exit status 0 is the verdict. (Nine deleted paths; `apps/` itself is an empty directory,
which git does not track — that is correct, not a leftover.)

### 4b. Stale references that intentionally stay (do NOT touch them)

None of these is read by the mount path (provision/observe/quality for a target-mode
roster), so gates A–E and the toy-app legs are unaffected. They are residual
de-vendoring debt for a later pass, and all are outside this run's authorization:

- `just/inkwell.just` — the `run`/`dev` recipes still exec `bun run apps/inkwell/server.ts`,
  so `just inkwell run` is now a broken recipe. (App-specific machinery left in the
  factory; the closest thing to a real gap in this list.)
- `TREE.md` line ~95 — the "## `apps/inkwell/` — the app" section documents a deleted tree.
- `adws/adw_modules/quality.py:44` `DEFAULT_APP_PATH = "apps/inkwell"` and
  `adws/adw_modules/data_types.py` `AppConfig.path` default — defaults only; every roster
  in play sets `app.path` explicitly.
- `sandbox_mount/guest/provision.sh:175` — `app.get("path") or "apps/inkwell"` fallback default.
- `justfile:38` `mod inkwell 'just/inkwell.just'` — the module still parses; `just --list` is fine.

Report these in the blocked report's "residual" section; change none of them.

### 4c. Also record why this chain still reaches its commit phase

This chain's roster (`sssf.meta3.config.yaml`) is intentionally vendored-mode
(`app.path: apps/inkwell`, no `repo`), so `payload_root` → factory root and the host-side
`verify_1` quality phase finds no manifest at `apps/inkwell/sssf.app.yaml` →
`_load_checks` returns `[]` → `QualityResult(passed=True)` → `verified` is True → the
`commit` phase runs and lands everything. That trivial pass is expected, not the
generality proof; the real quality proof is the blocked fresh-VM leg.

## Task 5 — stage (allowed) and leave the tree dirty

Optional but harmless: `git add adws/adw_modules/git_helper.py adws/adw_sssf_config/`.
Do NOT commit. The commit phase runs `git add -A` anyway and will also pick up the
planner's spec under `specs/`. After the chain's commit, `git status --porcelain` should
be empty (the session runtime under `adws/adw_data/` is gitignored).

## Task 6 — the blocked report (this is a required deliverable)

Write `adws/adw_data/sessions/83c5881a/context_handoff/blocked_report.md` (that path is
the session runtime — always writable, and gitignored so it never enters the commit).
It must contain both blockers:

### 6a. The push dependency (fresh-VM legs)

FILL clones the factory from the PUBLIC fork on `origin`. This chain commits locally and
may not push, so a VM cannot prove the de-vendored factory until the `apps/inkwell`
deletion is on `origin/main`. State verbatim:

> **BLOCKED: needs push of `origin/main` → the sha of this chain's landing commit.** The
> exact sha cannot be known before the chain's commit phase; the chain's final envelope
> records it. This agent must not push.

Then name the follow-up run (after the operator pushes): mount the toy app with
`sssf.hello.config.yaml` + a hello `.env`; `just sbx mount <id>` with gates A–E green;
observe the app 200 anonymous on `:4501`; a one-line in-sandbox SDLC
(`just sbx lifecycle execute <id> "…" "" simple-sdlc`) whose manifest-driven quality gate
passes — with **zero factory code edits**.

### 6b. The manifest-schema blocker I found this session (report it; do not fix it here)

Verified by loading hello-server's manifest at
`89b1ae17dbf7b0d48c9200cabc11333a26faf56d` through the real loader:

```bash
uv run --with pydantic --with pyyaml --with python-dotenv --with rich python - <<'EOF'
import subprocess, sys, types
sys.path.insert(0, "adws")
from pathlib import Path
from adw_modules import quality

tmp = Path("/tmp/sssf-manifest-check")
(tmp / "target").mkdir(parents=True, exist_ok=True)
(tmp / "ctx").mkdir(parents=True, exist_ok=True)
subprocess.run(["git", "clone", "-q", "--depth", "1",
                "https://github.com/yhuangsh/hello-server.git", "target"],
               cwd=tmp, check=True)
run = types.SimpleNamespace(
    cfg=types.SimpleNamespace(app=types.SimpleNamespace(path="target", manifest="sssf.app.yaml")),
    repo_root=tmp, context_handoff_dir=tmp / "ctx", phases=[])

print("as shipped :", end=" ")
try:
    print("loaded", [c.name for c in quality._load_checks(run)])
except Exception as e:
    print("FAILED", type(e).__name__, "-", e)
# contrast: the list form is what the loader expects
(tmp / "target" / "sssf.app.yaml").write_text(
    "checks:\n  - name: tests\n    argv: [bun, test, server.test.ts]\n")
print("list form  :", end=" ")
try:
    print("loaded", [c.name for c in quality._load_checks(run)])
except Exception as e:
    print("FAILED", type(e).__name__, "-", e)
EOF
```

Expected and verified output:

```
as shipped : FAILED TypeError - string indices must be integers, not 'str'
list form  : loaded ['tests']
```

Consequences to state plainly:

- Provisioning is unaffected (`provision.sh`'s manifest probe reads `runtime`, `install`,
  `build` — never `checks`), so the mount gates A–E and the observe-200 leg are fine.
- The in-sandbox SDLC's test/quality phase (`adw_simple_sdlc.py` → `quality.run_inkwell_tests`
  → `_load_checks`) raises `TypeError` and the leg fails. It reaches this with the app
  side of the manifest, at `~/app/target/sssf.app.yaml`, unchanged.
- Two paths to resolve it, both outside this run's authorization:
  1. **App-side (recommended):** rewrite `hello-server`'s `sssf.app.yaml` `checks:` to
     the list form the factory reads —
     `- name: tests / area: backend / operation: build / argv: [bun, test, server.test.ts] / timeout_seconds: 600`
     (operation has no `test` enum member; the name carries it, exactly as inkwell's
     manifest does). App-repo data only; the "zero factory code edits" claim stays true.
     Requires a push to `hello-server`, which the operator owns.
  2. **Factory-side:** teach `quality._load_checks` the compact-map shorthand (map key →
     check name, value → argv with `area=backend`, `operation=build`, 120 s). This is a
     `quality.py` change and needs its own run that is authorized for
     `adws/adw_modules/quality.py` — this chain explicitly is not.
- The same finding is recorded in the committed header comment of
  `sssf.hello.config.yaml`'s `app:` block (Task 3b), so it survives without the report.

### 6c. Residual (out of scope, reported not fixed)

The Task 4b list — chiefly `just/inkwell.just`'s now-broken `run`/`dev` recipes and
`TREE.md`'s `apps/inkwell/` section.

## Envelope template (BuilderOutput)

`status: "success"`, and:

```json
{
  "status": "success",
  "summary": "Verified the host-mode payload_root fallback in all three modes, reviewed the accurate sssf.config.yaml comment, finalized the hello-server generality-proof roster (adding a caveat comment for the compact checks: map that quality._load_checks cannot read), and confirmed apps/inkwell/ (9 tracked files) is fully deleted. The fresh-VM toy-app legs are BLOCKED: they need a push of origin/main to this chain's landing sha, and the toy app's manifest-driven quality gate additionally needs hello-server's `checks:` map conformed to the loader's list schema (or a separately authorized quality.py change). No ref mutation was run; the tree is left dirty for the chain's commit phase. Deleted: apps/inkwell/README.md, package.json, public/app.js, public/index.html, public/style.css, server.test.ts, server.ts, sssf.app.yaml, validation.png.",
  "changed_files": [
    "adws/adw_modules/git_helper.py",
    "adws/adw_sssf_config/sssf.config.yaml",
    "adws/adw_sssf_config/sssf.hello.config.yaml",
    "adws/adw_sssf_config/sssf.meta3.config.yaml"
  ],
  "artifacts": [],
  "commit_message": "De-vendor the factory: payload_root host fallback, hello-server generality roster, drop apps/inkwell",
  "notes_for_next_agent": "<how to verify: Task 1/3a/4a commands, all exit 0; the blocked_report.md path; the manifest `checks:` caveat and its two candidate fixes; `apps/inkwell` appears in the deletion as text because the gate rejects claims of nonexistent files>"
}
```

Rules for this envelope:

- `changed_files` lists **only** the four paths above — every one exists after the change.
  The nine deleted `apps/inkwell/*` paths go in `summary`/`notes`, **never** here.
- `artifacts` stays `[]` (the blocked report is runtime, not a repo artifact). If you
  prefer to name it, use the full existing path
  `adws/adw_data/sessions/83c5881a/context_handoff/blocked_report.md` — it will exist.
- `commit_message` is the subject of the commit that lands this work; the commit phase
  uses it verbatim. Keep it imperative and one line.
- `notes_for_next_agent` must carry the blocked line from 6a verbatim plus the exact
  `blocked_report.md` path.

## Done means

1. `payload_root` returns the factory root for vendored, host-target-no-clone, and
   dir-but-not-a-repo rosters, and the checked-out target clone in the in-VM layout —
   all four asserted by a script that exits 0 (Task 1).
2. `sssf.config.yaml`'s comment is kept as-is (accurate); `sssf.meta3.config.yaml` is
   byte-for-byte the operator's run roster, included in the landing commit.
3. `sssf.hello.config.yaml` is tracked, loads with 5 agents, differs from the default
   roster only in the `app:` block (+ its header + the 3b caveat comment), and names
   itself the generality proof.
4. `apps/inkwell/` is gone: no directory, no leftover file, nine tracked deletions.
5. `changed_files` is truthful and contains no deleted path; the deletion is text.
6. `adws/adw_data/sessions/83c5881a/context_handoff/blocked_report.md` exists and carries
   6a (push dependency + follow-up legs) and 6b (manifest-schema blocker + both fixes).
7. Everything lands in this chain's `commit` phase; the tree is clean afterwards. No
   agent ran any ref mutation.

## Out of scope (do not touch, do not report as a gap)

- Pushing to any remote (including `hello-server`).
- Inkwell re-verification; the ref-publishing guard; the rollback-index bug; a
  `deleted_files` envelope-contract extension.
- `quality.py` / `data_types.py` / `provision.sh` / `TREE.md` / `just/inkwell.just`
  edits — protected or unauthorized.
- Deleting or re-narrowing `sssf.meta3.config.yaml` (that happens in the follow-up run,
  after the VM legs pass — same precedent as the phase-2 meta roster).
