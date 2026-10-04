# Spec: generalize the sandboxed factory to mount ANY app repo

## Goal

Today the sandbox mounts exactly one thing: the factory repo, with the inkwell
app vendored inside it at `apps/inkwell`. This spec defines the end-state where
the **factory code is byte-identical across apps** and the only per-app inputs
are:

1. **`.env`** — the app's credentials (unchanged mechanism: allowlisted env
   vars shipped by FILL into the VM, 0600, stdin only).
2. **`sssf.config.yaml`** — the app's roster/config, extended with one `app:`
   block that names the target repo and how to run it.

The phase shape (`create -> fill -> setup -> observe`, explicit teardown) does
not change. `apt` stays banned (measured ~148 kB/s from dal, ~35 s/package;
every runtime below comes from its own CDN in seconds).

## Decision 1 — factory-toolbelt + app-target, NOT single-clone

**Recommendation: two clones on the VM — the factory toolbelt at `~/app`
(unchanged, byte-identical for every app) and the app target at
`~/app/target/` (per-app, gitignored inside the factory clone).**

### Why not single-clone

Single-clone means every app repo must vendor the entire factory (`adws/`,
`just/`, `sandbox_mount/`, `.claude/skills/sssf/`, the justfile). That fails
the brief on its face — the factory code would be *copied* per app, not
identical-by-reference — and it has three concrete costs:

- **Upgrade fan-out.** A factory fix (e.g. the provision.sh node-bootstrap of
  run 9466f202) would have to be merged into every app repo before that app's
  sandboxes benefit. Toolbelt+target upgrades every app the moment the factory
  repo advances, because FILL always clones factory HEAD.
- **History pollution.** Harvest bundles `BASE..HEAD` off the run branch. In
  single-clone the app repo's history carries every factory commit and every
  factory-runtime commit; separating "the app's change" from "the factory's
  machinery" becomes an archaeological exercise.
- **Gate A ambiguity.** Gate A asserts a clean factory tree; in single-clone
  the tree *is* the app, so factory-runtime writes and app writes are
  indistinguishable in one `git status`.

### Why the target lives INSIDE the factory clone at `target/`

The design fact stands: sssf.db, `context_handoff/`, and the ADW layer all
live inside the one clone the phases `cd` into. Keeping the target at
`~/app/target/` preserves every existing entry point (`cd app && just adw`,
`cd app && pi ...`, `cd app && {{CMD}}`) — the factory clone remains the
single ssh cwd, runtime state stays exactly where it is, and the ADW layer
needs no "second root" concept for its own machinery. The costs are two
one-line changes:

- Factory `.gitignore` gains `/target/` so gate A's `git status --porcelain`
  stays clean with a target checked out (this is a *factory* change, shipped
  once, identical for all apps).
- The phases that operate on the *payload* (run branch, harvest, app launch)
  address `~/app/target` instead of `~/app` or `~/app/apps/inkwell`.

A sibling `~/target` was considered and rejected: it spreads the on-box layout
across two roots, forces every remote command to name both, and buys nothing —
gate A's cleanliness is equally served by one `.gitignore` line.

### What changes hands in the one-clone design fact

Nothing about *runtime state* moves: sssf.db, `adws/adw_data/sessions/`,
context_handoff, specs/, app_docs/, run.log all stay in the **factory** root,
exactly as today (today's specs/ already mixes inkwell and sandbox specs — the
report trail is factory-scoped by precedent). What moves is the *payload
source and its commits*: the run branch `sbx/<run-id>` is created on the
**target** clone, and HARVEST bundles from the target. The factory clone is
never committed to inside a sandbox — which makes gate A *stronger*, not
weaker: any porcelain line in `~/app` is unambiguously machinery tampering.

## Decision 2 — per-app dependency mechanism

**The app repo declares its own needs in `sssf.app.yaml` at its root. The
provisioner consumes it generically. No apt, ever.**

### The manifest: `sssf.app.yaml` (lives in the APP repo)

```yaml
# sssf.app.yaml — what this app needs from a blank exeuntu VM.
runtime: bun            # bun | node | uv | none  — CDN-bootstrapped toolchains
install:                # shell commands run once at provision, from the app root
  - bun install
build: []               # e.g. [ "bun run build" ]; [] for interpret-and-serve apps
serve:                  # optional: how OBSERVE starts the app
  command: bun run server.ts
  port: 4501            # the ONE port the exe.dev proxy exposes anonymously
  health_path: /        # OBSERVE curls https://<host><health_path> for 200
checks:                 # optional: quality-gate commands, run from the app root
  lint:    [bun, x, oxlint@1.15.0, server.ts]
  test:    [bun, test, server.test.ts]
```

### How the provisioner consumes it

`sandbox_mount/guest/provision.sh` is already host-streamed (run 9466f202), so
it does not depend on clone content and can be evolved freely. Steps 1–4 (repo
root, bun, just, node/pi) and the factory-runtime steps (visualizer install +
`vite build`, trace-db DDL, uv warm) are **factory-generic and stay**. The
app-coupled remainder — today's step 5 hardcoding `bun install apps/inkwell` —
becomes one generic **app step**:

1. Resolve the app dir: `$REPO_ROOT/$APP_PATH` where `APP_PATH` comes from the
   `app:` block of the shipped roster (`/home/exedev/sssf_config.yaml`),
   defaulting to `apps/inkwell` during migration (see below).
2. Read `sssf.app.yaml` there. Parsing uses the already-provisioned `uv run`
   with a PEP-723 inline script (pyyaml is already a tracer dependency) — the
   same pattern as the trace-db step, no new binary.
3. **Runtime**: ensure the declared runtime is on PATH. `bun` and `node` are
   already bootstrapped by steps 2/4 from bun.sh / nodejs.org; `uv` already
   ships in the image. A runtime the image and steps 2–4 don't cover fails
   fast with a named error — it is NEVER an excuse for apt.
4. **install/build**: run each declared command in a subshell from the app
   dir, echoing each under a `── app ──` step banner so the ERR trap names
   the stage. Absent manifest or absent key = skip with a `say` line, never a
   failure (mirrors today's `skipped (no package.json)` behavior).
5. **Fallback when no manifest exists**: if `package.json` is present, run
   `bun install`. This keeps un-instrumented app repos mountable for SDLC
   work even before they add a manifest; only OBSERVE's app lane and the
   quality checks need the manifest's `serve:`/`checks:` sections.

### Bandwidth discipline (unchanged)

All runtimes arrive as CDN tarballs (bun.sh, nodejs.org, astral.sh) measured
at ~1 s each. Language-level package installs (bun install, uv sync, npm -g)
go to their registries, not apt. The provision header comment's "NEVER add
apt" rule extends verbatim to the app step.

## Decision 3 — the `app:` block in `sssf.config.yaml`

The roster file is already the per-app varying artifact and is already shipped
verbatim by FILL to `/home/exedev/sssf_config.yaml`. It gains one top-level
block:

```yaml
app:
  repo: https://github.com/<owner>/<app-repo>.git   # public, unauthenticated clone
  ref: main                 # optional; branch/tag/sha, default remote HEAD
  path: target              # mount point inside the factory clone
  manifest: sssf.app.yaml   # optional override; default <path>/sssf.app.yaml
```

- **FILL** (`just/sandbox/lifecycle/fill.just`) keeps its hardcoded factory
  `REPO` (line 28) — the factory source is app-independent. After cloning the
  factory and passing its pin gate, FILL reads the `app:` block from the
  **host-side** roster (`$SSSF_CONFIG`, the same file the roster-ship step
  already reads), clones `app.repo` into `~/app/<path>` (idempotent fetch /
  ff-only, same pattern as the factory clone), checks out `app.ref`, and
  creates the run branch `sbx/<run-id>` **on the target**. The roster ship
  (~lines 146–190) is untouched.
- **Run record**: `commit_sha` now means the *target's* checked-out HEAD (it
  is the harvest baseline, and harvest is about the app's commits). A new
  field `factory_sha` records the factory clone's HEAD. FILL's existing
  pin/gate logic applies to both clones; a pin that resolves in neither fails
  fast as today.
- **Gate A** (setup.just) asserts: factory HEAD == `factory_sha` AND factory
  tree clean (with `/target/` gitignored, the checkout does not dirty it) AND
  target HEAD == `commit_sha`. Gates B–E are app-agnostic and unchanged.
- **HARVEST** (`just/sandbox/manage/harvest.just` line 58): `cd app/target`
  instead of `cd app`; the `BASE..HEAD` bundle mechanics are identical.
- **TEARDOWN** (`just/sandbox/lifecycle/teardown.just` line 77): the tar set
  `specs app_docs adws/adw_data/sssf.db run.log` is factory-root state and is
  unchanged; it gains `target/sssf.app.yaml` (tiny, and records exactly what
  the box ran) — the target's *code* returns via the harvest bundle, not tar.
- **EXECUTE / run lanes** (`execute.just`, `run/mod.just`): unchanged. The
  ADW still runs from the factory root (`cd app && just adw ...`); agents
  reach the payload at `target/`, which is inside their cwd and unprotected
  (factory `protected_files` covers only `adws/` machinery, so builder access
  to `target/**` needs no permission change).

## Decision 4 — OBSERVE for non-inkwell apps

`observe.just` lines 36–38 hardcode `APP_DIR=$HOME/app/apps/inkwell` and
`bun run server.ts` on 4501. Generalize:

- The app lane reads `app.path` from the shipped roster and the `serve:`
  section from the target's manifest (one `uv run` YAML probe over ssh, or
  awk-parsed like the roster's `defaults:` block — decide at build time, but
  ONE parser, not two).
- **Start**: `cd $HOME/app/<path> && ( PORT=<port> nohup <command> > $HOME/app-server.log ... )`
  with the same three detachment pieces and `wait_listen` poll as today. The
  log name de-brands from `inkwell-app.log` to `app-server.log`.
- **Port**: the manifest's `serve.port` (default 4501) is what the proxy
  shares anonymously. One anonymous port per VM is an exe.dev constraint, not
  ours to relax here.
- **Health**: the anonymous curl asserts 200 on `health_path` (default `/`).
- **No `serve:` section**: the app lane is *skipped, not failed* — a library
  or CLI app has nothing to expose. OBSERVE prints `no serve: in manifest —
  app lane skipped`, still starts the visualizer, and still shares/sets-public
  the declared-or-default port only when a server was started.
- The visualizer lane (4600) is factory machinery and is byte-for-byte
  unchanged.

## Decision 5 — the ADW quality layer follows the manifest

`adws/adw_modules/quality.py` hardcodes inkwell (`oxlint apps/inkwell/...`,
`bun test apps/inkwell/server.test.ts`, bun builds). In the end-state the
check set comes from the manifest's `checks:` map, resolved against the app
dir. Inkwell's current six checks are re-expressed as its manifest entries, so
the inkwell run's quality gate is behavior-identical. Apps with no `checks:`
get a single default: the manifest's `checks.test` if present, else no
quality phase (the SDLC still runs plan/build/review). This is the only
ADW-layer code change; `agents.py`, `permissions.py`, the tracer, and the
config loader are untouched.

## File-by-file touchpoints (all verified this session)

| File | Change |
|---|---|
| `just/sandbox/lifecycle/fill.just` | Factory REPO stays; add target clone + run branch on target; record `factory_sha`; read `app:` block from host roster |
| `just/sandbox/lifecycle/setup.just` | Gate A extends to target HEAD; gates B–E unchanged; shipped-config default unchanged |
| `just/sandbox/lifecycle/observe.just` | App lane driven by roster `app.path` + manifest `serve:`; skip-if-absent; de-branded log |
| `sandbox_mount/guest/provision.sh` | Steps 5–8 → factory-runtime steps (visualizer, trace db, uv warm) + generic manifest-driven app step |
| `just/sandbox/lifecycle/teardown.just` | Tar set gains `target/sssf.app.yaml`; otherwise unchanged |
| `just/sandbox/lifecycle/execute.just`, `just/sandbox/run/mod.just` | No change — `cd app` remains correct |
| `just/sandbox/manage/harvest.just` | `cd app/target`; bundle mechanics unchanged |
| `just/sandbox/orch/mod.just` + orchestrator SKILL.md | Document the `app:` block as the per-app input |
| `adws/adw_modules/quality.py` | Check set from manifest `checks:` with inkwell-expressed defaults |
| `adws/adw_sssf_config/sssf.config.yaml` | Gains the `app:` block (schema above) |
| Factory `.gitignore` | Add `/target/` |
| `sandbox_mount/host/run_record.py` | New `factory_sha` field (record schema is closed by convention — this is the one sanctioned extension) |

## Migration path — gates A–E green for inkwell at every step

1. **Phase 0 — schema + compat default.** Add the `app:` block to
   `sssf.config.yaml` with `path: apps/inkwell` and no `repo:` (meaning:
   payload is in the factory clone, today's layout). Fill/setup/observe read
   the block but resolve to byte-identical behavior. `commit_sha` keeps its
   current meaning; `factory_sha` is recorded but gate A compares it against
   the same HEAD. **Verify: `just sbx mount` for inkwell, gates A–E green,
   observe 200 — zero behavior change.**
2. **Phase 1 — manifest-driven provision + quality.** Write
   `apps/inkwell/sssf.app.yaml` expressing exactly today's behavior (bun
   install; serve `bun run server.ts` on 4501; the six quality checks).
   Rewrite provision steps 5–8 generically and quality.py manifest-driven.
   **Verify: mount inkwell again; provision output shows the same installs;
   gates A–E green; a small `execute` SDLC passes its quality gate.**
3. **Phase 2 — target mode.** Extract inkwell to its own public repo; factory
   `.gitignore` += `/target/`; set `app.repo` + `path: target` in the inkwell
   roster. FILL clones into `~/app/target`, run branch moves there, harvest
   and gate A follow. **Verify: full cycle — mount (A–E green), observe (app
   200 anonymous, obs gated), execute a one-line SDLC, harvest bundles the
   target commits (`git bundle verify` passes against the recorded base),
   teardown pulls artifacts.**
4. **Phase 3 — factory de-vendoring.** Remove `apps/inkwell/` from the
   factory repo (the factory now contains no app code). Mount a second, toy
   app repo (a `sssf.app.yaml`-carrying hello-server) end-to-end with only a
   new roster + `.env`. **Verify: gates A–E green on the toy app with zero
   factory edits.**

Each phase is independently committable and independently green; a failure in
phase N leaves phase N−1 as the working system.

## Out of scope (respected)

Implementing any of this; credential design beyond `.env`'s existing
allowlist; multi-app-per-VM; any change to the create→fill→setup→observe
phase shape.
