# Plan: Rewrite README.md for the generalized sssf sandbox factory

## Objective

Rewrite `README.md` **in place** so it describes the GENERALIZED sandbox factory:
the factory repo contains **no app code**; each app is an external public git repo
carrying a `sssf.app.yaml` manifest at its root; per-app inputs are exactly one
roster file in `adws/adw_sssf_config/` plus the `.env` LLM keys. The README must
walk a reader end to end through setting up a NEW app and using the sandbox in
development, using the shipped hello-server worked example.

**Only `README.md` changes.** No code, no other docs (`app_docs/`, `specs/` stay
as they are). `changed_files` in the envelope: exactly `["README.md"]`. No git
ref mutations — do not commit; the chain's commit phase owns that.

## Accuracy constraint (the hard rule of this task)

Every command, path, roster field, and manifest key illustrated must exist. The
facts below were verified against the live tree this session — trust them, but
re-verify anything you quote that is not listed here (recipe names via
`just --list`, `just sbx`, `just sbx lifecycle`, `just sbx manage`, `just sbx run`,
`just adw`, `just obs`, `just local`).

## Verified facts (recon this session)

### Command surface (verified against justfiles)

- `just sbx manage doctor` — five checks: ssh exe.dev reachable, run_record
  helper runs, provisioner present, roster provider keys set, adw layer resolves.
  Success line: `sbx doctor: OK` (`just/sandbox/manage/mod.just`).
- `just sbx mount <RUN_ID>` — chains `lifecycle create → fill → setup → observe`
  and prints the resolved run id plus execute/agent/harvest/destroy follow-ups
  (`just/sandbox/mount.just`). Stops at observe by design; teardown is never
  chained.
- Six phases = six recipes: `just sbx lifecycle create|fill|setup|execute|observe|teardown <run-id>`
  (`just/sandbox/lifecycle/`).
- **`just sbx lifecycle execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA`** —
  the prompt is the SECOND argument; the ADW chain is the FOURTH. The task
  prompt's sketch `execute <id> <adw-chain> "<prompt>"` is WRONG — document the
  real signature, e.g.:
  `just sbx lifecycle execute my-run "add a /health endpoint"` (default `sdlc`), or
  `just sbx lifecycle execute my-run "add a /health endpoint" "" simple-sdlc`.
  Detached; PID recorded in the run record; `run.log` on the box; watch with
  `just sbx run cmd <id> 'tail -f run.log'`.
- `just sbx run agent <run-id> "<prompt>"` — hands off to **pi** (not Claude
  Code) inside the box over a resumable session (`--session-id` creates or
  continues). The old README's "in-sandbox orchestrator = resumable Claude Code
  session" is OUTDATED.
- `just sbx run cmd <run-id> '<cmd>'` — synchronous escape hatch, `cd app` first.
- `just sbx manage list`, `just sbx manage harvest <run-id>`,
  `just sbx lifecycle teardown <run-id>`.
- `just obs sessions|phases <adw_id>|tail <adw_id>|procs <adw_id>|ui`
  (`just/obs.just`); trace db at `adws/adw_data/sssf.db`.
- `just adw` recipes that exist: `sdlc`, `simple-sdlc`, `plan-build-test-quality`,
  `plan-build-test`, `build-test`, `build-review`, `plan-build`, `plan`, `build`,
  `scout`, `quality`, `document`, `prompt`, `ask`. There are 12 `adws/adw_*.py`
  scripts ("twelve ADWs" in the old README is still accurate).
- `just local cc|pi|ipi` and `just sbx orch cc|pi` still exist — Claude Code is
  host/orch only. `agent_cc.py` is a stub: the factory v1 is Pi-only
  (`coding_agent: claude_code` errors by name).

### Roster / per-app inputs (verified against `adws/adw_sssf_config/sssf.hello.config.yaml`, `fill.just`, `.env.sample`)

- Shipped worked example: `adws/adw_sssf_config/sssf.hello.config.yaml`, whose
  `app:` block is:
  ```yaml
  app:
    repo: https://github.com/yhuangsh/hello-server.git   # public, unauthenticated clone
    ref: main
    path: target
    manifest: sssf.app.yaml
  ```
- `app:` block fields that exist: `repo` (public clone URL), `ref`, `path`
  (default `target` when repo set), `manifest` (default `sssf.app.yaml`). No
  `repo` = vendored mode (legacy Phase 0/1 compat); the generalized story is
  target mode.
- Active roster is selected by **`SSSF_CONFIG`** (env var; default
  `adws/adw_sssf_config/sssf.config.yaml`). Read by the root justfile,
  `just/adws.just`, `fill.just`, `harvest.just`, `teardown.just`,
  `roster_keys.sh`. `.env.sample` line 49 documents it (commented) and the sbx
  modules `set dotenv-load`, so `SSSF_CONFIG=...` in `.env` works. Six rosters
  now ship: `sssf.config.yaml`, `sssf.hello.config.yaml`, `sssf.deepestseek`,
  `sssf.frontier`, `sssf.open-weights`, `sssf.top-speed`.
- `.env` LLM keys: allowlisted provider keys (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
  `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, `ZAI_CODING_CN_API_KEY`, …). FILL ships the
  ones you set to `app/.env` (0600) on the VM; `roster_keys.sh` fails fast
  naming missing ones for the active roster's providers.
- **STALE CAVEAT — do not propagate:** the hello roster file carries an inline
  comment claiming map-form `checks:` break `quality.py`. That was fixed by spec
  `4e0c9038_quality-checks-map-form.md`: `quality._load_checks` accepts BOTH the
  map form (`checks: {test: [bun, test, server.test.ts]}`) and the list form
  (`[{name, area, operation, argv}]`). The README must state both forms work.

### Manifest `sssf.app.yaml` (verified against `specs/6159cbd5_any-app-factory-mount.md` and `provision.sh`)

Lives at the APP repo root. Keys:
```yaml
runtime: bun            # bun | node | uv | none
install:                # shell commands run once at provision, from the app root
  - bun install
build: []               # e.g. ["bun run build"]; [] for interpret-and-serve
serve:                  # optional — OBSERVE's app lane; no serve: = library/CLI, skipped not failed
  command: bun run server.ts
  port: 4501            # the ONE port exposed anonymously
  health_path: /        # OBSERVE curls https://<host><health_path> for 200
checks:                 # optional — the SDLC quality gate; map OR list form
  test: [bun, test, server.test.ts]
```
hello-server (the toy app) declares exactly this shape: bun runtime,
`bun install`, serve `bun run server.ts` on 4501, `checks.test`.

### Sandbox internals (verified against `provision.sh`, `fill.just`, `setup.just`, `observe.just`, `harvest.just`)

- App clones to `~/app/target` (i.e. `$HOME/app/<app.path>`) on the VM; the
  factory clone is `~/app`. ADW products commit to the target clone's run branch
  `sbx/<run-id>`.
- Provisioner is **host-streamed** (`bash -s` over ssh stdin — the same version
  as the host-side gates, never the VM's copy): bun from bun.sh, just from
  just.systems, node+npm from nodejs.org, **pi at registry-latest**
  (`npm install -g @earendil-works/pi-coding-agent` after resolving the
  `latest` dist-tag), then the manifest-driven app step (runtime check, install,
  build), visualizer install + `bunx vite build`, trace-db DDL. **apt never.**
- Gates A–E (setup.just, host-side, leave the VM up on failure):
  A git integrity (factory HEAD + target HEAD vs run record, clean factory tree),
  B pi current (== registry latest) and `--list-models` non-empty,
  C roster ping through the sandbox's own pi,
  D non-zero cost,
  E credential coverage for every roster provider.
- Ports: app on the manifest's `serve.port` (4501 for hello-server; the one
  anonymous port), trace UI (visualizer) on **4600**, auth-gated to exe.dev
  users with VM access.
- Harvest (target mode): bundles `sbx/<run-id>` commits from the target clone,
  verifies against a dedicated bare cache `.sandbox/repos/hello-server.git`,
  lands them as `refs/sandbox/<run-id>` IN THAT CACHE; bundle kept at
  `.sandbox/runs/<run-id>.bundle`. Read with
  `git -C .sandbox/repos/hello-server.git log --oneline --graph <base>..refs/sandbox/<run-id>`.
  Never merges; never touches the factory repo's refs in target mode.
- Trace: every phase/tool call/thought streams into `adws/adw_data/sssf.db`
  (WAL); `just obs ui` serves the visualizer.

### What is no longer accurate in the current README (must change)

- The tagline and intro ("A blog app, the factory that builds it…") — the
  factory is now app-agnostic; the app is external and brought by the user.
- "Tier 1: Inkwell, the payload" — `apps/` is now EMPTY (de-vendored, Phase 3,
  spec `83c5881a`); inkwell's history moved to
  `https://github.com/yhuangsh/inkwell.git`. Do NOT document `cd apps/inkwell &&
  bun install`, `just inkwell run/dev/test`, or `just inkwell test  # 30 tests`
  as setup steps. (The `just inkwell` namespace still exists in the justfile but
  its recipes point at a path that is no longer vendored — do not feature it as
  a flow; the safest treatment is to drop the inkwell namespace from the
  command-surface section and let the roster/manifest story carry the app.)
- "In-sandbox orchestrator agent — resumable Claude Code session" → it is pi
  (see above). The equip line referencing
  `.claude/skills/sssf/SKILL.md` is still valid (the skill exists).
- Harvest description "commits come home as `refs/sandbox/<run-id>`" — in the
  generalized (target) mode they land in the bare app-repo cache
  `.sandbox/repos/<repo>.git`, not the factory repo. Describe target mode.
- "the whole repo ships to the VM" / app served from factory clone — reframe:
  the factory clone ships as the toolbelt; the app is its own clone.

### What stays accurate (keep, lightly re-edited)

- Agentic Install (`/install`, `/prime` exist in `.claude/commands/`),
  `just sbx manage doctor` preflight, the Required Tech table (drop the
  inkwell-specific rows/wording: bun is still required for the
  factory/visualizer, uv for the ADWs; Claude Code only for `just local cc` /
  `just sbx orch cc`).
- "Why this exists", the credential boundary (exe.dev account host-only; LLM
  keys shipped as `app/.env`; one level of nesting), "Watch it run" (trace db,
  two ports — update framing to "your app's port + 4600"), "Where it can still
  fail", License, footer. Existing images may be kept; re-caption only where the
  caption says something now false (e.g. Inkwell-specific claims). Do not add
  new images.
- Six-phase story, "agent proposes, code disposes", envelopes/gates language,
  best-of-N fan-out (execute's CONFIG arg still supports it).

## Section-by-section instructions

Restructure README.md to roughly this shape (adapt headings to the repo's
voice; keep the repo's existing tone and image usage where accurate):

1. **Title + intro** — generalized framing: "the software factory and the
   throwaway sandbox it runs in — bring your own app." State the three facts:
   factory repo has no app code; an app is a public repo with `sssf.app.yaml`
   at root; per-app input = one roster file + `.env` keys. Keep the YouTube
   link and any still-accurate hero image.
2. **Install** — Agentic Install (`/install`, `/prime`) and Manual Install
   (`cp .env.sample .env`, set LLM keys, `just sbx manage doctor`; NO app-dep
   step — the app is external). Keep Required Tech, corrected.
3. **Why this exists / credential boundary / Who commands what** — keep, with
   the pi-orchestrator correction.
4. **The app contract (new section, replaces "Tier 1: Inkwell")** — the
   manifest schema (exact keys above, both `checks:` forms), the roster `app:`
   block, hello-server as the worked example (link
   `https://github.com/yhuangsh/hello-server.git`, the shipped roster, port
   4501). State that a missing manifest falls back to `bun install` when
   `package.json` is present, and a missing `serve:` block skips the app lane
   rather than failing.
5. **The factory** (old Tier 2) — keep; update roster count to six and note
   `sssf.hello.config.yaml` is the per-app roster worked example.
6. **The sandbox** (old Tier 3) — keep; ensure the six phases, host-streamed
   provisioner (node+npm bootstrap, pi at registry-latest, manifest-driven app
   deps, apt never), run branch `sbx/<id>` on the target clone.
7. **End-to-end: set up a new app and develop in a sandbox** (replaces "How to
   run it end to end") — the four numbered parts from the task:
   - (0) Prerequisites: exe.dev account + ssh (`ssh exe.dev whoami` is what
     doctor checks), `.env` keys, `just sbx manage doctor` → `sbx doctor: OK`.
   - (1) New app: make the repo public with `sssf.app.yaml` at root (show the
     hello-server manifest), `cp adws/adw_sssf_config/sssf.hello.config.yaml
     adws/adw_sssf_config/sssf.myapp.config.yaml`, edit the `app:` block
     (repo/ref/path/manifest), set `SSSF_CONFIG=adws/adw_sssf_config/sssf.myapp.config.yaml`
     in `.env`, set the LLM keys the roster's providers need, re-run doctor.
   - (2) Mount: `just sbx mount my-run` (create → fill → setup → observe;
     gates A–E named; app on :4501 anonymous, trace UI on :4600 auth-gated;
     prints run id + URLs).
   - (3) Develop: `just sbx lifecycle execute my-run "add a /health endpoint"`
     (default `sdlc`; show the 4-arg form for picking a chain like
     `simple-sdlc`); `just sbx run agent my-run "..."` and `just sbx run cmd
     my-run 'tail -f run.log'`; watch with `just obs sessions` / `just obs tail
     <adw_id>` (distinguish `<run-id>` = sandbox vs `<adw_id>` = one factory
     run); `just sbx manage harvest my-run` (bundle + refs/sandbox ref in
     `.sandbox/repos/<repo>.git`, read it with `git -C ... log/diff`, never
     merges); `just sbx lifecycle teardown my-run` (always explicit).
   - (4) How it works (short): the six phases and the run record as the only
     shared state; agents-plus-code ("agent proposes, code disposes");
     envelopes carry context, gates validate claims (failure re-enters the
     same session as a correction); the trace db (`adws/adw_data/sssf.db`,
     WAL, visualizer on 4600).
8. **Watch it run / command surface / Where it can still fail / License /
   footer** — keep, updated per the corrections above. Command surface tree:
   drop or re-frame `inkwell`; `adw` list per verified recipes; `sbx` subtree
   mount/lifecycle/run/manage/orch; `obs`; `local`.

## Builder verification checklist (run before finishing)

1. `just --list`, `just sbx`, `just sbx lifecycle`, `just sbx manage`,
   `just sbx run`, `just adw`, `just obs`, `just local` — every recipe named in
   the README appears in this output. Judge by exit status.
2. `grep` the final README for `apps/inkwell`, `just inkwell`, `bun install`
   host-side steps, `Claude Code session` inside the sandbox — none may remain
   (Claude Code may only appear as host/orch tooling and the `/install` agent).
3. Every roster field shown (`repo`, `ref`, `path`, `manifest`) exists in
   `adws/adw_sssf_config/sssf.hello.config.yaml`; every manifest key shown
   matches `specs/6159cbd5_any-app-factory-mount.md` §manifest.
4. `git diff --stat` shows exactly one file: `README.md`. Leave the tree dirty —
   do NOT commit.
5. The hello-server example must match the shipped roster byte-for-byte on the
   `app:` block values (repo URL, `ref: main`, `path: target`,
   `manifest: sssf.app.yaml`).

## Done means

README.md updated in place; every illustrated command/path/field verified
against the sources above; no stale inkwell-as-vendored-payload content; no
other file touched; tree left dirty for the chain's commit phase.
