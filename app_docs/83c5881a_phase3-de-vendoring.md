# Phase 3 Factory De-vendoring

## Summary

Phase 3 lands: the factory clone no longer carries any app code. `apps/inkwell/`
(the only app ever vendored into the factory clone, going back to Phase 0) is
gone — its history now lives at `https://github.com/yhuangsh/inkwell.git`. A
new roster `sssf.hello.config.yaml` points at `https://github.com/yhuangsh/hello-server.git`
and is the **generality proof**: the de-vendored factory can mount a different
toy app using only a new roster plus a `.env`, with zero factory code edits.
The work also fixes a regression that this transition exposed —
`git_helper.payload_root()` returned `<factory>/target` unconditionally when a
roster's `app.repo` was set, which crashed every host-side target-mode ADW run
because FILL creates that clone only inside the VM.

## Why It Matters

Phases 0–2 of the any-app factory (spec `6159cbd5`) shipped with `apps/inkwell`
vendored in the factory clone. The roster's `app:` block named the GitHub
mirror, but the working code lived at `apps/inkwell/` and the host-side
shortcuts (`quality.py`'s `DEFAULT_APP_PATH = "apps/inkwell"`,
`provision.sh`'s `app.get("path") or "apps/inkwell"` fallback,
`just/inkwell.just`'s `run`/`dev` recipes) all leaned on that vendored copy.

Phase 3 removes the vendored copy outright. The factory clone becomes
byte-identical across apps — a target-mode roster that names a repo clones that
repo into `~/app/<path>` inside the VM and the factory is untouched. The hello
roster proves this property: drop in a new roster that names a different
public app repo, and the factory mounts it without modification.

The host-mode regression was a side-effect of that transition: the old
behaviour always returned the factory root (vendored = factory-side), so
`payload_root()` was never asked to honour an `app.repo` field. Once
target-mode became the default for the production roster, `payload_root()`
started handing back a path that does not exist on the host — and every host
git call died with `FileNotFoundError` before the first phase could run. The
fallback added in this change makes host-side target-mode runs return the
factory root (where their products belong), and in-VM target-mode runs return
the checked-out clone.

## Changed Files

### `adws/adw_modules/git_helper.py` — host-mode fallback for `payload_root()`
`payload_root(app_cfg, factory_root)` now only returns
`Path(factory_root) / app_cfg.path` when that path is **both** a directory and
a real git repo (`is_repo()` runs `git rev-parse --git-dir`); otherwise it falls
back to `Path(factory_root).resolve()`. The short-circuit order matters — the
`target.is_dir()` test must run before `is_repo(target)`, because
`is_repo()` would otherwise fail with `FileNotFoundError` on a missing path.
The docstring is expanded to name the host-side vs in-VM distinction and the
rationale.

### `adws/adw_sssf_config/sssf.config.yaml` — comment update
Two lines of comment in the `app:` block preamble change. The old line "`apps/inkwell`
stays vendored until Phase 3 and is simply unused here." is replaced by
"Phase 3 de-vendored: no app code lives in the factory clone (inkwell's history
is at https://github.com/yhuangsh/inkwell.git)." The `app:` block itself is
unchanged — it was already in target-mode (`repo`, `ref`, `path: target`,
`manifest: sssf.app.yaml`).

### `adws/adw_sssf_config/sssf.hello.config.yaml` — new "generality proof" roster
A 172-line copy of the default roster whose **only functional difference** is
the `app:` block, plus a header comment that names it the generality proof:

```yaml
app:
  repo: https://github.com/yhuangsh/hello-server.git   # public, unauthenticated clone
  ref: main                 # verified at 89b1ae17dbf7b0d48c9200cabc11333a26faf56d (git ls-remote)
  path: target
  manifest: sssf.app.yaml   # carried by the app repo: bun runtime, install,
                            # serve `bun run server.ts` on 4501, checks.test
```

Loads via `agents.load_config` with five agents
(`planner, builder, scout, reviewer, documenter`), same as the default roster.
The remaining roster content (defaults block, observability, every agent's
permissions/prompt paths) is byte-identical to `sssf.config.yaml`.

The `manifest:` block carries an inline **CAVEAT** documenting a real bug this
session found: hello-server's manifest declares `checks:` as the compact map
`{test: [bun, test, server.test.ts]}`, but `quality._load_checks` iterates a
**list** of `{name, area, operation, argv}` mappings and calls `entry["name"]`
— the map raises `TypeError: string indices must be integers`. The caveat
points to the two resolution paths (rewrite `checks:` in hello-server's repo,
or change `quality.py` in a separately authorized run) and to the blocked
report for the full evidence.

### `adws/adw_sssf_config/sssf.meta3.config.yaml` — run roster, planner model fallback
Three lines under `agents > planner > model` change. The old `model:
kimi-coding/k3` is replaced by `model: deepseek/deepseek-flash` with a comment
naming the trigger: `kimi-coding/k3` hit a 5-hour provider usage limit on
2026-10-04 (HTTP 403 quota). No other content of the roster changes — it is
the run-time configuration for this chain (intentionally vendored-mode with
`app.path: apps/inkwell` so the host-side `verify_1` quality phase finds no
manifest and trivially returns `passed=True`, allowing the chain's commit
phase to land the work).

### `apps/inkwell/` — full removal (9 tracked files)
All nine tracked files under `apps/inkwell/` are deleted:
`README.md`, `package.json`, `public/app.js`, `public/index.html`,
`public/style.css`, `server.test.ts`, `server.ts`, `sssf.app.yaml`,
`validation.png`. The `apps/` directory itself is empty after the deletion
(git does not track empty directories — that is correct, not a leftover).

### `specs/83c5881a_phase3-devendoring-land.md` — planner spec
388-line resume plan authored by the planner. Documents the verify-and-land
workflow, the four `payload_root` modes the harness asserts, the
`sssf.hello.config.yaml` finalization (parsing identity proof + caveat
comment), the `apps/inkwell/` removal verification, the staging rules, the
blocked-report contents, and the out-of-scope list (no `quality.py` edit, no
push, no follow-up legs in this chain).

## How to Verify

The plan's three verification scripts are the source of truth. Re-running each
should exit 0 from the factory root.

**Task 1 — `payload_root` in all four cases.** Loads `git_helper` and asserts
each of:
1. Vendored (`AppConfig(path="apps/inkwell")`) → factory root.
2. Target-mode, no clone at `<factory>/<path>` → factory root (the new fallback).
3. Target-mode, `<root>/<path>` exists but is not a git repo → factory root
   (covers the `/tmp/sssf-payload-check/notgit/target` placeholder case).
4. In-VM layout, a real clone is checked out at `<factory>/<path>` → the clone.

Each is asserted, and case (2) additionally drives `git_helper.rev("HEAD", …)`
to prove the first git call no longer raises `FileNotFoundError`. The scratch
clone lives under `/tmp/sssf-payload-check/` so the factory tree is never
touched.

**Task 3a — hello roster loads and differs only in `app:`.** Parses both
rosters with `yaml.safe_load`, drops the `app:` key, and asserts structural
equality. Then asserts `app:` for both rosters matches the expected repo/ref/path
values. Then runs `agents.load_config(...)` and asserts five agent names in
order. Comments cannot move any of these — that is the point.

**Task 4a — `apps/inkwell/` removal.** A single shell pipeline: `test ! -d
apps/inkwell` (directory is gone), `find apps -mindepth 1` returns nothing
(no leftover files), and `git status --porcelain | grep '^ D apps/inkwell/'`
counts to 9 (every previously tracked file under `apps/inkwell/` is now a
deletion).

## What's Still Blocked

Two blockers are recorded in
`adws/adw_data/sessions/83c5881a/context_handoff/blocked_report.md`
(the session runtime — gitignored, never enters the commit):

1. **Push dependency.** The fresh-VM legs cannot run until the operator pushes
   `origin/main` to this chain's landing commit. The follow-up run then mounts
   the toy app with `sssf.hello.config.yaml` + a hello `.env`, runs `just sbx
   mount <id>` with gates A–E green, observes the app 200 anonymous on `:4501`,
   and runs `just sbx lifecycle execute <id> "…" "" simple-sdlc` whose
   manifest-driven quality gate must pass — all with zero factory code edits.

2. **Manifest-schema blocker (found this session).** `quality._load_checks`
   iterates `checks:` as a list of `{name, area, operation, argv}` mappings
   but hello-server's `sssf.app.yaml` ships `checks:` as the compact map
   `{test: [bun, test, server.test.ts]}`. The map form raises `TypeError` at
   the in-sandbox test phase and aborts the leg. Two resolution paths, both
   outside this run's authorization: rewrite `hello-server`'s `checks:` to
   the list form (app-side, no factory changes), or teach `quality.py` the
   map shorthand (factory-side, needs its own authorized run). The same
   finding is committed as an inline CAVEAT in `sssf.hello.config.yaml`'s
   `app:` block so it survives without the report.

The plan's Task 4b also names the residual stale references this chain
intentionally did **not** touch: `just/inkwell.just` (broken `run`/`dev`
recipes), `TREE.md`'s deleted `apps/inkwell/` section, and three defaults
(`quality.DEFAULT_APP_PATH`, `AppConfig.path`, `provision.sh`'s `apps/inkwell`
fallback) that no roster in play depends on. None are read by the mount path.
