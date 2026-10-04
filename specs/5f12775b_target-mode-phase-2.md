# Plan: Phase 2 (target mode) of the any-app factory mount spec

Parent spec: `specs/6159cbd5_any-app-factory-mount.md` (a.k.a.
`adws/adw_data/sessions/6159cbd5/context_handoff/plan.md`), migration step 3
("Phase 2 — target mode"). Phases 0 and 1 are already landed (see
`specs/4c8321b5_app-manifest-phases-0-1.md`, `specs/d142f7cb_land-phases-0-1.md`).

## What Phase 2 is

The payload stops being the vendored `apps/inkwell` and becomes its own clone:
the PUBLIC app repo `https://github.com/yhuangsh/inkwell.git` (main at
`395ade8`, verified live via `git ls-remote` and raw fetches — it carries
`sssf.app.yaml` at its root with a `serve:` block and all seven `checks:`).
FILL clones it into `~/app/target` on the VM, the run branch `sbx/<id>` is
created **on the target**, `commit_sha` becomes the target's HEAD (harvest
baseline) and `factory_sha` keeps the toolbelt's HEAD. Gate A, OBSERVE's app
lane, HARVEST, TEARDOWN's tar set, and the ADW commit plumbing follow.

`apps/inkwell/` STAYS in the factory repo this phase (de-vendoring is Phase 3).
It sits there tracked and untouched; gate A stays green because nothing writes
to it.

## Hard constraints (operator)

- Do NOT create or push any repo. The app repo already exists. The factory
  fork (`origin = yhuangsh/inkwell-agent-sandboxes-and-software-factory`) must
  not be pushed by an agent either. If a push turns out to be needed, report
  it in the envelope (see "The push dependency" below — it IS needed for part
  of the verification; that is expected, not a planning gap).
- The working tree currently has one uncommitted modification:
  `adws/adw_sssf_config/sssf.meta.config.yaml` (the one-off protected_files
  lift authorizing this run, header documents why). It is part of this
  landing — commit it with the phase-2 changes so the tree ends clean. Stay
  inside the spec's scope anyway: the lift authorizes the paths, it does not
  widen the task.
- No ref-publishing guard, no rollback-index bug fix, no Phase 3.

## Pre-verified facts (this session)

- `git ls-remote https://github.com/yhuangsh/inkwell.git` → HEAD = main =
  `395ade856cd09c925458cfe74b9768db50377fed`. `sssf.app.yaml` and `server.ts`
  exist at that sha (raw.githubusercontent, 200).
- `adws/adw_modules/data_types.py` already has `AppConfig{repo, ref, path,
  manifest}` and `SSSFConfig.app` — no schema work needed.
- `sandbox_mount/host/run_record.py` already supports `factory_sha`; FILL
  already records it (= factory HEAD today); setup gate A already tolerates an
  empty `factory_sha`.
- `provision.sh` step 5 is already fully generic (uv PEP-723 probe reads
  `app.path`/`app.manifest` from `/home/exedev/sssf_config.yaml`, then the
  manifest's `runtime`/`install`/`build`). Pointing `app.path` at `target` is
  all it needs — **provision.sh is untouched this phase.**
- `adws/adw_modules/quality.py` is already manifest-driven and resolves the
  app dir as `run.repo_root / cfg.app.path` — works unchanged with
  `path: target`.
- `observe.just` is still inkwell-hardcoded (`APP_DIR='$HOME/app/apps/inkwell'`,
  `bun run server.ts`, `inkwell-app.log`, health on `/`) — Phase 2 generalizes it.
- `harvest.just` does `cd app` remotely and `git bundle verify` + `git fetch`
  into the HOST factory repo — both need target-mode handling (see below).
- Commit plumbing: `git_helper.commit_all(message)` is called from
  `adw_plan_build.py:67-70`, `adw_plan_build_test.py:74`,
  `adw_plan_build_test_quality.py:86`, and `adw_simple_sdlc.py:70` (one helper
  used by three phases). `changes.capture` (`adw_simple_sdlc.py:152`,
  `adw_document.py:48`) diffs via the same cwd-bound `git_helper` functions.
  All git calls in `git_helper.py`/`changes.py` run in the process cwd =
  factory root.
- Agents spawn with `cwd = run.repo_root` (factory root) — UNCHANGED. Builders
  reach the payload at `target/`, inside their cwd.
- `permissions.py` snapshots the factory repo only; `target/` will be
  gitignored there, so builder writes to `target/**` never register — exactly
  the spec's "needs no permission change". UNCHANGED this phase.
- Local HEAD == `origin/main` == `09e194d`. `just adw` recipe names:
  `sdlc` (adw_plan_build_test), `simple-sdlc` (adw_simple_sdlc),
  `plan-build-test-quality`.

## Changes, file by file

### 1. `adws/adw_sssf_config/sssf.config.yaml` — the roster's `app:` block

Replace the Phase-0-compat comment and block with:

```yaml
app:
  repo: https://github.com/yhuangsh/inkwell.git   # public, unauthenticated clone
  ref: main
  path: target
  manifest: sssf.app.yaml
```

Update the comment above it: Phase 2 target mode — FILL clones `repo` into
`~/app/target`, the run branch and ADW commits move to that clone, harvest
bundles from it. Note that `apps/inkwell` remains vendored until Phase 3 and
is simply unused. Nothing else in the roster changes.

### 2. `.gitignore` — factory change, one line

Add under the "sssf runtime" section, with a comment:

```
# Phase 2: the app target clone lives inside the factory clone. Ignored so gate
# A's `git status --porcelain` stays clean with a target checked out.
/target/
```

Root-anchored on purpose: only the top-level mount point, never an app file
named `target`.

### 3. `just/sandbox/lifecycle/fill.just` — clone the target, branch on it

Factory REPO, clone, pin gate, roster ship, settings.json, .env ship: all
UNCHANGED. The changes:

- **Parse the `app:` block from the host roster** (`$ROSTER`, the same
  variable the roster-ship step already computes) with awk, same style as the
  existing `defaults:` probes:
  ```bash
  APP_REPO=$(awk '/^app:[[:space:]]*$/ {a=1; next} /^[^[:space:]]/ {a=0}
                  a && /^[[:space:]]+repo:[[:space:]]/ {print $2; exit}' "$ROSTER")
  APP_REF=...   # same pattern; empty = remote HEAD
  APP_PATH=...  # same pattern; default "target" when APP_REPO is set
  ```
- **Vendored mode** (`APP_REPO` empty): byte-identical to today — run branch
  on the factory clone, `commit_sha` = `factory_sha` = factory HEAD.
- **Target mode** (`APP_REPO` set):
  - The factory remote script no longer creates `sbx/<run-id>` on the factory
    clone (the factory is never committed to inside a sandbox). Keep the
    clone/fetch/ff-only/pin logic; drop the branch block in target mode.
  - Record `factory_sha` = factory HEAD right after the factory pin gate
    (gate-first-then-record, as today).
  - A second remote script over ssh stdin mirrors the factory clone pattern
    for the target, taking `app_repo`, `run_id`, `app_path`, `app_ref` as
    positionals (ref LAST — the optional-argument-must-be-last lesson is in
    the existing comment):
    - `app/<path>/.git` present → `git -C app/<path> fetch --quiet --tags
      origin`; if no ref, `checkout main && merge --ff-only origin/main`
      (warn, never reset, on non-ff).
    - else → `rm -rf app/<path>` (half-finished clone is not state) and
      `git clone --quiet "$repo" "app/$path"`.
    - ref set → `git -C app/<path> checkout --quiet "$ref"`.
    - run branch `sbx/<run-id>`: `rev-parse --verify` → `switch` to it and
      ff-only-advance to the ref when one was given (warn on non-ff, exactly
      the factory script's semantics), else `switch -c`.
    - print `"<target_head> <intended>"` on stdout; progress to stderr.
  - Target pin gate: ref set but unresolvable, or HEAD ≠ intended → fail
    fast, VM left up, `commit_sha` left untouched (harvest baseline intact —
    same discipline as the factory gate).
  - Record `commit_sha` = target HEAD.
- Echo lines name which mode ran ("vendored payload" vs "target clone").

### 4. `just/sandbox/lifecycle/setup.just` — gate A asserts both HEADs

Only gate A changes; B–E untouched. REMOTE_A gains roster parsing (awk on
`$1`-style positional or re-read `$CONFIG` — it already receives `$SHA` and
`$FACTORY_SHA` as positionals; pass the config path as a third positional) and:

- Factory HEAD must prefix-match `factory_sha` when set (assertion already
  exists — keep; it is now the *primary* factory assertion).
- Factory `git status --porcelain` must be empty — unchanged. With `/target/`
  in the clone's `.gitignore` the checkout does not dirty the tree. **This is
  the line that needs the pushed factory commit on a fresh VM** — see the push
  dependency section.
- `app.repo` present in the roster → target HEAD (`git -C
  "$HOME/app/$APP_PATH" rev-parse HEAD`) must prefix-match `commit_sha`, and
  the target dir must be a git repo at all (fail with a named error
  otherwise). Do NOT assert a clean *target* tree: provision's `bun install`
  may legitimately rewrite `bun.lock`.
- `app.repo` absent → today's behavior verbatim (commit_sha compared against
  the factory HEAD).
- Update the header comment and the `[gate] A PASS` line to say which mode was
  asserted.

### 5. `just/sandbox/lifecycle/observe.just` — manifest-driven app lane

- **One YAML parser, the one provision.sh already established**: a `uv run`
  PEP-723 probe (pyyaml dependency, stdout = shlex-quoted assignments, probe's
  own resolve noise to stderr) run over ssh against
  `/home/exedev/sssf_config.yaml` + `$HOME/app/<path>/<manifest>`, emitting
  `APP_PATH`, `SERVE_PRESENT`, `SERVE_COMMAND`, `SERVE_PORT` (default 4501),
  `SERVE_HEALTH_PATH` (default `/`). Do not add a second parser style; awk
  stays reserved for the roster's flat blocks.
- App lane (step [2/6]):
  - `SERVE_PRESENT=0` → print `no serve: in manifest — app lane skipped` and
    skip the start, the `share port`/`set-public`, and the anonymous-200
    verification. The visualizer lane, the ports record (obs only), and the
    final URL banner still run. A library/CLI app is not a failure.
  - Otherwise `APP_DIR='$HOME/app/<path>'`, start with all three detachment
    pieces verbatim from today plus the port:
    `cd $APP_DIR && ( PORT=<port> nohup <command> > $HOME/app-server.log 2>&1 < /dev/null & echo $! )`
    (`nohup VAR=x cmd` does not work — the assignment goes before `nohup`,
    exactly like the visualizer's `SSSF_DB=` line). `wait_listen` polls the
    manifest port; on timeout tail `~/app-server.log` (de-branded from
    `inkwell-app.log` everywhere: start line, failure tails, comments).
- Proxy step: `share port "$VM" "$APP_PORT"` + `set-public` only when a server
  was started (spec: the declared-or-default port is shared only then).
- Verify: anonymous curl asserts 200 on `https://$HOST<health_path>` (the
  retry loop stays), obs port check unchanged (000/5xx fail, anything else is
  the expected gate).
- Ports record: `{"app":<port>,"obs":4600}` when started, `{"obs":4600}` when
  skipped.

### 6. `just/sandbox/manage/harvest.just` — bundle from the target

- Parse the roster's `app:` block host-side (same awk as fill). `APP_REPO`
  set → target mode, `REPO_DIR="app/$APP_PATH"`; else `REPO_DIR="app"`.
- Remote script: `cd "$REPO_DIR"` instead of `cd app`; the NOREPO /
  branch-at-HEAD / NOCOMMITS / bundle-create mechanics are identical. BASE is
  the record's `commit_sha`, which is now the target HEAD — correct already.
- Host side in target mode the bundle's prerequisite (target base commit) is
  NOT in the factory repo, and the app commits must not be fetched into the
  factory repo either. Add a bare cache:
  - `CACHE=".sandbox/repos/$(basename "$APP_REPO" .git).git"` (e.g.
    `.sandbox/repos/inkwell.git`; `.sandbox/` is already gitignored).
  - Missing → `git clone --bare --quiet "$APP_REPO" "$CACHE"`; present →
    `git -C "$CACHE" fetch --quiet --tags origin` (public, unauthenticated —
    refreshes the base prerequisite).
  - `git -C "$CACHE" bundle verify "$BUNDLE"`, then `git -C "$CACHE" fetch
    --force --quiet "$BUNDLE" "refs/heads/$BRANCH:$DEST"`.
  - Vendored mode keeps today's verify-into-the-factory-repo behavior.
  - Final echo lines use `git -C "$CACHE"` in target mode for the
    log/diff instructions.

### 7. `just/sandbox/lifecycle/teardown.just` — tar set gains the manifest

Parse the `app:` block host-side (same awk). In target mode, add
`"$APP_PATH/$APP_MANIFEST"` to the remote `ls -d` list (it filters
non-existent paths, so a run that died before the clone is not an error).
Comment: the target's *code* returns via the harvest bundle; the manifest
comes along because it records exactly what the box ran. Everything else
unchanged (`specs app_docs adws/adw_data/sssf.db run.log` are factory-root
state by design).

### 8. `adws/adw_modules/git_helper.py` — the payload repo

- Every public function gains an optional keyword `repo: Path | str | None =
  None`, threaded into the `subprocess.run(..., cwd=repo)` calls (`_git`,
  `is_repo`, `commit_all`, `ref_exists`, `rev`, `short_sha`, `merge_base`,
  `is_dirty`, `untracked_files`, `diff_files`, `diff_stat`, `diff_counts`,
  `diff_text`). `None` = today's behavior, so no existing caller breaks.
- New function:
  ```python
  def payload_root(app_cfg, factory_root: Path) -> Path:
      """The repo ADW products commit to: the target clone when the roster's
      app block names a repo (phase 2 target mode), else the factory repo
      itself (vendored payload — byte-identical to the old behavior)."""
      if app_cfg is not None and getattr(app_cfg, "repo", None):
          return (Path(factory_root) / app_cfg.path).resolve()
      return Path(factory_root).resolve()
  ```
- `commit_all(message, repo=None, allow_empty: bool = False)`: with
  `allow_empty` and a clean tree, log-and-return `""` instead of raising
  "nothing to commit". The strict raise stays the default.
- Module docstring gains a paragraph: in target mode the factory clone is
  never committed to inside a sandbox; specs/ and app_docs/ products live
  factory-side, uncommitted, and ride home in the teardown tar.

### 9. `adws/adw_modules/changes.py` — diff the payload repo

`capture(run, params)` resolves `repo = git_helper.payload_root(getattr(
run.cfg, "app", None), run.repo_root)` once and threads it through
`resolve_base` and every `git_helper` call. In vendored mode `repo` IS the
factory root, so the diff is byte-identical to today. The `ChangeCapture.base`
ref a caller pins must name a commit IN THE PAYLOAD REPO — callers updated
below.

### 10. The four ADW scripts — commit to the payload repo

`adw_plan_build.py`, `adw_plan_build_test.py`,
`adw_plan_build_test_quality.py`, `adw_simple_sdlc.py`:

- After `session.ensure`: `payload = git_helper.payload_root(cfg.app,
  run.repo_root)`.
- Baselines: `git_helper.rev("HEAD", repo=payload)` (adw_simple_sdlc's
  `baseline`; the request phase's `short_sha(baseline)` call likewise).
- Commit calls: `git_helper.commit_all(message, repo=payload)`.
- `adw_simple_sdlc.commit()` gains a per-phase empty policy:
  `commit_plan` and `commit_docs` pass `allow_empty=True` (in target mode the
  plan lands in factory-side `specs/` and the write-up in factory-side
  `app_docs/` — the payload repo is legitimately clean for those phases, and
  the phase logs `sha="" ` plus a note that the artifact rides home via the
  teardown tar); `commit_build` stays strict — a build that changed nothing
  in the payload IS an anomaly, and `changes.capture` right after would fail
  honestly on it anyway.
- `adw_document.py` needs no edit beyond changes.py's internals (its `--base`
  default `main` exists in the target clone).

`agents.py`, `permissions.py`, `tracer.py`, `quality.py`, `runner.py`:
UNCHANGED (verified above that each is already correct under target mode).

### 11. Docs touchpoints (small)

- `just/sandbox/orch/mod.just` header / `.claude/skills/sssf/SKILL.md`: one
  short paragraph each where the roster is described — the `app:` block is
  THE per-app input (`repo`/`ref`/`path`/`manifest`); with `repo` set the
  payload is its own clone at `~/app/<path>` and the factory stays
  byte-identical across apps. Read both files first and match their tone; no
  restructuring.

### 12. `adws/adw_sssf_config/sssf.meta.config.yaml`

Already modified in the working tree (the operator's protected_files lift for
this run). Leave its content exactly as the operator wrote it and include it
in the landing commit — its header is the authorization record. Do NOT
delete or re-narrow it in this chain; its header says that happens when
phase 2 lands, i.e. after verification, which is partially blocked on the
push (below).

## The push dependency (read before verifying)

FILL clones the factory from the hardcoded PUBLIC fork
(`origin` = `yhuangsh/inkwell-agent-sandboxes-and-software-factory`,
currently at `09e194d`). This chain commits phase 2 LOCALLY and may not push.
Two phase-2 changes must be present *inside the VM's clone*:

1. `.gitignore` gaining `/target/` — without it gate A's
   `git status --porcelain` prints `?? target/` and FAILS the mount.
2. The payload-aware `adw_modules` plumbing — without it the in-sandbox SDLC
   runs the old `commit_all` against the factory repo, where `target/` is
   untracked, so the build commit either grabs the wrong repo or raises
   "nothing to commit".

Everything else reaches the VM from the host already: provision.sh is
streamed (setup.just), the roster is shipped verbatim (fill.just), and
fill/setup/observe/harvest/teardown run from the host's working tree.

**Protocol for the builder:** after committing phase 2 locally, run
`git ls-remote origin main` and compare with local HEAD. If they differ, the
fresh-VM legs below CANNOT pass and the builder must NOT push to fix that —
it runs every host-side check, states in its envelope that origin/main must
advance to the local phase-2 sha, and marks the fresh-VM legs
"blocked: needs push of origin/main → <local sha>". If they match (the
operator pushed), run the full cycle below for real.

## Verification

Host-side, always (even when the VM legs are blocked):

1. `just --list > /dev/null` (every edited just file still parses in the root
   scope) and `bash -n` on any extracted scripts.
2. `uv run adws/adw_plan_build.py --help > /dev/null` and the same for
   `adw_simple_sdlc.py` (PEP-723 imports resolve; the git_helper/changes
   edits load).
3. A LOCAL vendored-mode regression: with a scratch roster copy that has NO
   `app.repo` (Phase 0 layout), run `uv run adws/adw_plan_build.py "tiny
   no-op-scoped prompt" --config <scratch>` far enough to see the commit
   phase still commit to the factory repo (or unit-level: `uv run python -c`
   exercising `payload_root`/`commit_all(repo=...)` against a temp repo in
   /tmp). Keep any scratch repo in /tmp, never in the working tree.
4. Local commit: `git status --porcelain` empty at the end; commit message
   covering fill/setup/observe/harvest/teardown/gitignore/roster/adw_modules.

Fresh-VM end-to-end (only when origin/main carries the phase-2 sha):

5. `just sbx mount <task>` (create→fill→setup→observe). Expected: fill logs
   the target clone and run branch on the target; gate A asserts factory HEAD
   == factory_sha AND target HEAD == commit_sha AND clean factory tree; gates
   B–E green.
6. Observe: anonymous `curl https://<host>/` → 200 on the declared port
   (4501, from the target's manifest), visualizer port 4600 reachable but
   owner-gated (307/401), app log at `~/app-server.log`.
7. One-line SDLC on the target:
   `just sbx lifecycle execute <id> "In target/, add a GET /health endpoint to server.ts that returns {\"ok\":true}" "" simple-sdlc`
   then poll `just sbx run cmd <id> 'tail -f run.log'` to completion.
   Expected: `git -C app/target log --oneline` on the VM shows the run's
   commit(s) on `sbx/<id>` (build commit at minimum; plan/docs commits may be
   skipped-empty by design), and `cd app && git status --porcelain` on the
   FACTORY shows only the factory-side runtime artifacts (specs/, app_docs/),
   never target/.
8. `just sbx manage harvest <id>`: bundle created from `app/target`,
   `git bundle verify` passes against the recorded base in
   `.sandbox/repos/inkwell.git`, `refs/sandbox/<id>` lands there with the
   run's commits.
9. `just sbx lifecycle teardown <id>`: artifacts pulled (specs, app_docs,
   sssf.db, run.log, `target/sssf.app.yaml`), harvest already done, VM
   destroyed, record closed.

## Out of scope (do not touch)

- Phase 3: removing `apps/inkwell/` from the factory repo, mounting a second
  toy app.
- The ref-publishing guard, the rollback-index bug.
- Pushing anything to any remote (report instead).
- `provision.sh`, `execute.just`, `run/mod.just`, `quality.py`,
  `permissions.py`, `agents.py`, `runner.py`, `tracer.py` — verified already
  correct under target mode.

## Done means

All file changes above landed and committed with a clean tree; host-side
checks 1–4 pass; the fresh-VM legs 5–9 either pass for real (origin pushed)
or are reported in the envelope as blocked on the origin/main push with the
exact sha — never pushed by the agent.
