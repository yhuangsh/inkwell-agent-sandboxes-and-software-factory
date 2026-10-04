# Plan: host-mode `payload_root` fix + phase 3 (factory de-vendoring)

Parent spec: `adws/adw_data/sessions/6159cbd5/context_handoff/plan.md`, migration
step 4 ("Phase 3 — factory de-vendoring"), plus the host-mode regression that
crashed runs 61ae1ec3 and the first phase-3 attempt at startup.

## Hard constraints (operator, apply to every agent)

- Do NOT run `git commit`, `git push`, `git checkout`, `git branch`, `git reset`,
  or any ref mutation. The chain's commit phases own every commit (four prior
  runs failed "nothing to commit" on builder self-commits). `git add` is allowed;
  leave the tree dirty and list every changed file in the envelope.
- This run's roster (`sssf.meta3.config.yaml`) authorizes the builder to touch
  exactly:
  - `adws/adw_modules/git_helper.py`
  - `adws/adw_sssf_config/sssf.config.yaml` (only if genuinely needed)
  - `adws/adw_sssf_config/sssf.hello.config.yaml` (new)
  - `adws/adw_sssf_config/sssf.meta3.config.yaml`
  - `apps/inkwell/` (deletion)
- Do NOT push anything to any remote. The fresh-VM legs are BLOCK-REPORTED (see
  "The push dependency" below).
- Out of scope: inkwell re-verification, the ref-publishing guard, the
  rollback-index bug, deleting `sssf.meta3.config.yaml` (see below).

## Current state (verified this session)

- `git_helper.payload_root()` (adws/adw_modules/git_helper.py lines 25–31):
  when `app_cfg.repo` is set it returns `(factory_root / app_cfg.path).resolve()`
  unconditionally. That clone (`<factory>/target`) exists only inside VMs —
  FILL creates it. On the host the dir is missing, and the very next call,
  `git_helper.rev("HEAD", repo=payload)` (adws/adw_simple_sdlc.py line 68),
  dies with `FileNotFoundError` because `subprocess.run(..., cwd=<missing>)`
  raises before git even runs. Same crash hits `adw_plan_build.py`,
  `adw_plan_build_test.py`, `adw_plan_build_test_quality.py`, and
  `changes.capture()` — all call `payload_root` then git against the result.
- This run's roster (`sssf.meta3.config.yaml`) is intentionally vendored-mode
  (`app:` has `path: apps/inkwell`, NO `repo:`), so this chain starts despite
  the regression. The DEFAULT roster (`sssf.config.yaml`) is target-mode
  (`repo: https://github.com/yhuangsh/inkwell.git`, `path: target`) — already
  external, no functional change needed after de-vendoring.
- `https://github.com/yhuangsh/hello-server.git` is public;
  `git ls-remote` shows `main = 89b1ae17dbf7b0d48c9200cabc11333a26faf56d`.
  It carries its own `sssf.app.yaml` (bun runtime, install, serve
  `bun run server.ts` on 4501, `checks.test`).
- Factory `.gitignore` already has `/target/` (phase 2), so a `target/` clone
  on the host does NOT dirty the tree — this makes the in-clone verification
  below safe.
- `quality.py` already tolerates a missing manifest: `_app_dir(run) /
  manifest_name` not a file → zero checks, "nothing to run" note, pass. So
  after `apps/inkwell/` is deleted, this run's host-side quality phase (meta3
  roster, `path: apps/inkwell`) passes trivially. That is expected, not a gap;
  the real quality proof for the toy app is the follow-up VM legs.
- Working tree at plan time: only `?? adws/adw_sssf_config/sssf.meta3.config.yaml`
  (untracked, the run roster — leave it; the chain's first commit may pick it up,
  that is fine and precedented).

## Task 1 — fix `payload_root` host-mode fallback

File: `adws/adw_modules/git_helper.py`. Replace the body of `payload_root`
(lines 25–31) with:

```python
def payload_root(app_cfg, factory_root: Path) -> Path:
    """The repo ADW products commit to: the target clone when the roster's app
    block names a repo AND the clone is checked out (phase 2 target mode, in
    a VM), else the factory repo itself (vendored payload — byte-identical to
    the old behavior).

    Host-side runs of a target-mode roster have no clone at <factory>/<path>
    (FILL creates it only inside the VM); their products belong to the factory,
    so a missing or non-git target falls back to the factory root instead of
    crashing the first git call with FileNotFoundError."""
    if app_cfg is not None and getattr(app_cfg, "repo", None):
        target = (Path(factory_root) / app_cfg.path).resolve()
        if target.is_dir() and is_repo(target):
            return target
    return Path(factory_root).resolve()
```

Notes:

- The `target.is_dir()` guard MUST come first: `is_repo()` runs
  `git rev-parse --git-dir` with `cwd=target`, which raises `FileNotFoundError`
  on a missing dir — the exact crash being fixed. Short-circuit order is the
  fix; do not "simplify" it away.
- `is_repo` already exists in this module (line ~40) — reuse it, no new helper.
- No other call site changes: every caller (`adw_simple_sdlc.py`,
  `adw_plan_build*.py`, `changes.py`) gets the fallback for free.

### Verify Task 1 (host-side, all three modes)

Run from the factory root. One inline script, judged by exit status:

```bash
uv run --with pydantic --with pyyaml python - <<'EOF'
import sys, subprocess
sys.path.insert(0, "adws")
from pathlib import Path
from adw_modules.data_types import AppConfig
from adw_modules import git_helper

root = Path.cwd()

# Mode 1 — vendored (this run's meta3 roster): no repo -> factory root
assert git_helper.payload_root(AppConfig(path="apps/inkwell"), root) == root

# Mode 2 — target mode, NO clone checked out (host): must fall back, not crash
t = AppConfig(repo="https://github.com/yhuangsh/hello-server.git", path="target")
assert not (root / "target").exists()
assert git_helper.payload_root(t, root) == root
# ...and the follow-on git call that used to crash now works:
git_helper.rev("HEAD", repo=git_helper.payload_root(t, root))

# Mode 3 — target mode, clone present (in-VM layout): must return the target
subprocess.run(["git", "clone", "-q", "https://github.com/yhuangsh/hello-server.git",
                "target"], check=True)
assert git_helper.payload_root(t, root) == (root / "target").resolve()
print("payload_root: all three modes OK")
EOF
```

Then `rm -rf target` (it is gitignored via `/target/`, so the tree stays clean;
removing it restores the host's no-clone state). The clone goes to `./target`
in the factory root, NOT /tmp, because `payload_root` resolves
`factory_root / app.path` — a /tmp clone would not exercise the real path.
This is a scratch checkout, deleted immediately after; it is not a repo write.

## Task 2 — phase 3: de-vendor the factory

### 2a. Delete `apps/inkwell/`

`rm -rf apps/inkwell` from the factory root. Do NOT use `git rm`: the chain's
commit phase runs `git add -A`, which stages the deletion on its own, and the
standing rule keeps agents away from git plumbing beyond `git add`. Inkwell's
history lives at https://github.com/yhuangsh/inkwell.git — nothing is lost.

Known stale references that stay (all out of authorization or harmless):

- `adws/adw_modules/quality.py:44` `DEFAULT_APP_PATH = "apps/inkwell"` and
  `adw_modules/data_types.py:357` `path: str = "apps/inkwell"` default —
  defaults only; this run's roster sets `app.path` explicitly, and quality.py's
  missing-manifest path passes trivially. NOT authorized to touch.
- `sssf.config.yaml` line ~45 comment "`apps/inkwell` stays vendored until
  Phase 3 and is simply unused here" — stale after this lands. The builder MAY
  update that one comment line (the roster is authorized "only if genuinely
  needed"; a stale comment is the only candidate). No functional change to the
  default roster's `app:` block — it is already external.

### 2b. Add `adws/adw_sssf_config/sssf.hello.config.yaml`

A byte-for-byte copy of `sssf.config.yaml` with exactly two differences:

1. A header comment block naming it the generality proof, e.g.:

```yaml
# sssf.hello.config.yaml — the generality proof for the any-app factory (spec
# 6159cbd5 phase 3): the de-vendored factory mounts a toy app with ONLY a new
# roster + .env, zero factory code edits. Identical to sssf.config.yaml except
# the app: block below.
```

2. The `app:` block:

```yaml
app:
  repo: https://github.com/yhuangsh/hello-server.git   # public, unauthenticated clone
  ref: main                 # verified at 89b1ae17dbf7b0d48c9200cabc11333a26faf56d (git ls-remote)
  path: target
  manifest: sssf.app.yaml   # carried by the app repo: bun runtime, install,
                            # serve `bun run server.ts` on 4501, checks.test
```

Everything else — defaults, protected_files, observability, all five agents —
is identical to the default roster. That identity IS the proof.

Validate it loads (exit status is the verdict):

```bash
uv run --with pydantic --with pyyaml --with python-dotenv --with rich python - <<'EOF'
import sys
sys.path.insert(0, "adws")
from pathlib import Path
from adw_modules import agents
cfg = agents.load_config(Path("adws/adw_sssf_config/sssf.hello.config.yaml"))
assert cfg.app.repo == "https://github.com/yhuangsh/hello-server.git"
assert cfg.app.path == "target"
assert len(cfg.agents) == 5
print("hello roster loads OK")
EOF
```

### 2c. Do NOT delete or re-narrow `sssf.meta3.config.yaml`

Its header says "Delete this roster when phase 3 lands." Phase 3 lands only
after the blocked fresh-VM legs pass in the follow-up run (same precedent as
phase 2's meta roster, kept until its VM legs ran in 462c1d84). This chain
leaves it untouched. Its vendored-mode `app.path: apps/inkwell` pointing at a
now-deleted dir is fine: `payload_root` → factory root (no `repo`), and
quality.py finds no manifest → trivial pass, as designed.

## The push dependency (blocked-report protocol)

FILL clones the factory from the PUBLIC fork on origin. This chain commits
locally and may not push; a VM cannot prove the de-vendored factory until the
deletion is on origin. Protocol (same as runs 5f12775b/462c1d84):

- The builder runs every host-side check above, then states in its envelope:
  the fresh-VM legs are **"blocked: needs push of origin/main → <local sha
  after this chain's commits>"** — the builder does not know the final sha, so
  it writes "the sha of this chain's landing commit" and the chain's final
  envelope records the exact sha. The builder never pushes to fix this.
- The follow-up run (after the operator pushes) executes the toy-app legs with
  `sssf.hello.config.yaml` + a hello `.env`: fresh `just sbx mount <id>`,
  gates A–E green, observe app 200 anonymous on :4501, a one-line in-sandbox
  SDLC passing the manifest-driven quality gate — zero factory code edits.

## Final checks before the builder hands off

1. Task 1 three-mode script passes; `rm -rf target` done.
2. `test ! -d apps/inkwell`
3. Hello-roster load script passes.
4. `git status --porcelain` shows exactly: `M adws/adw_modules/git_helper.py`,
   `?? adws/adw_sssf_config/sssf.hello.config.yaml`, `D` entries for
   `apps/inkwell/**`, optionally `M adws/adw_sssf_config/sssf.config.yaml`
   (comment only), plus the pre-existing `?? adws/adw_sssf_config/sssf.meta3.config.yaml`
   and this plan under `specs/`. Nothing else.
5. Envelope lists every changed file and carries the blocked-report line.

## Done means

- `payload_root` falls back to the factory root when a target-mode roster has
  no clone, returns the target when it does, factory root when no `repo` —
  all three verified host-side.
- `apps/inkwell/` deleted; `sssf.hello.config.yaml` added and loadable; default
  roster untouched or comment-only touched.
- All changes landed BY THIS CHAIN's commit phases (no agent self-commits);
  tree clean after the chain's commits.
- Blocked-report written: fresh-VM toy-app legs blocked on the origin/main
  push, exact landing sha recorded, follow-up run named as their executor.

## Out of scope (respected)

- Pushing to any remote; creating or deleting repos.
- Inkwell re-verification; the ref-publishing guard; the rollback-index bug.
- Deleting `sssf.meta3.config.yaml` (happens in the follow-up run, after the
  VM legs pass).
- `quality.py` / `data_types.py` `apps/inkwell` defaults — not authorized,
  harmless.
