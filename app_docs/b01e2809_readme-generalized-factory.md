# Document: README rewritten for the generalized sssf sandbox factory

## What changed

`README.md` was rewritten in place to describe the **generalized** sssf sandbox factory: the factory repo contains **no app code**, every app is an external public git repo that carries a `sssf.app.yaml` manifest at its root, and the only per-app inputs that live in the factory repo are one roster file in `adws/adw_sssf_config/` and the LLM provider keys in `.env`. The old framing — a blog app (`inkwell`) vendored inside the factory as the payload — is gone; the worked example is now the toy app `https://github.com/yhuangsh/hello-server.git`, shipped in roster `adws/adw_sssf_config/sssf.hello.config.yaml`.

The supporting spec for the rewrite also landed: `specs/b01e2809_readme-generalized-factory.md`. It captures the verified facts the README rests on (the real `lifecycle execute` signature, the new `SSSF_CONFIG` env var, both `checks:` forms, gates A–E, harvest into a bare app-repo cache) and the section-by-section instructions used to produce the README.

## Files

| File | Change | Why it matters |
| --- | --- | --- |
| `README.md` | rewritten (+210 / −62) | The first thing a new engineer reads. The old copy taught them to `cd apps/inkwell && bun install` and run `just inkwell test`; the new copy teaches them to publish a repo with `sssf.app.yaml` and add one roster. |
| `specs/b01e2809_readme-generalized-factory.md` | new (257 lines) | The spec the rewrite was scored against — the verified commands, paths, roster fields, and manifest keys. Stays as a reference so future README edits can be re-checked against it. |

## What the new README covers

Restructured around the generalized flow. The old "Tier 1 / Tier 2 / Tier 3" framing is replaced; the new sections are:

1. **Intro** — generalized tagline ("bring your own app"), the three-fact statement (factory / app / sandbox), `Install` and `Set up a new app and develop in a sandbox` as the two entry points.
2. **Install** — agentic (`/install`, `/prime`) and manual (`cp .env.sample .env`, `just sbx manage doctor`). The `cd apps/inkwell && bun install` line is removed; the new copy states explicitly that there is no host-side app-dep step.
3. **Required Tech** — kept, lightly edited. Bun is described as the runtime that serves the observability UI and bootstraps each sandbox per its manifest; Claude Code is downgraded to host/orch-only tooling; Pi is installed by the provisioner.
4. **The app contract** (new, replaces "Tier 1: Inkwell, the payload") — the `sssf.app.yaml` schema (`runtime`, `install`, `build`, `serve`, `checks`), the `app:` block of the roster (`repo`, `ref`, `path`, `manifest`), both `checks:` forms (map and list), the hello-server worked example with its shipped roster, and the two graceful fallbacks (no manifest → `bun install` if `package.json` exists; no `serve:` → app lane skipped, not failed).
5. **The factory** — old Tier 2 content kept; roster count updated to six (the five originals + `sssf.hello.config.yaml`); documents `SSSF_CONFIG` as the env var that selects the active roster.
6. **The sandbox** — old Tier 3 content kept; reframes "the whole repo ships to the VM" as "the factory clone ships as the toolbelt; your app is its own clone"; calls out the host-streamed provisioner (bun/just/node+npm from their CDNs, Pi at registry-latest, manifest-driven app deps, `apt` never), and the harvest target-mode destination (a bare cache of your app repo at `.sandbox/repos/<repo>.git`, never the factory repo).
7. **Set up a new app and develop in a sandbox** (replaces "How to run it end to end") — the four numbered parts called for in the spec:
   - **(0) Prerequisites** — `ssh exe.dev whoami`, `cp .env.sample .env` + LLM keys, `just sbx manage doctor` ending in `sbx doctor: OK`. The doctor is described as a five-check preflight (ssh, helpers, provisioner, roster provider keys, adw layer).
   - **(1) Set up a new app** — make the repo public with `sssf.app.yaml` at its root, `cp adws/adw_sssf_config/sssf.hello.config.yaml adws/adw_sssf_config/sssf.myapp.config.yaml`, edit the `app:` block (repo/ref/path/manifest), set `SSSF_CONFIG=adws/adw_sssf_config/sssf.myapp.config.yaml` in `.env`, set the LLM keys the roster's providers need, re-run doctor.
   - **(2) Mount** — `just sbx mount my-run` chains create → fill → setup → observe (~10s), prints run id + URLs. The five-assertion health gate is named (A git integrity, B pi current, C roster ping, D non-zero cost, E credential coverage). The two ports are called out: the app on the manifest's `serve.port` (4501 for hello-server — the one anonymously exposed port) and the trace UI on 4600, auth-gated.
   - **(3) Develop** — `just sbx lifecycle execute my-run "<prompt>"` for the default `sdlc` chain (the README shows the real `RUN_ID PROMPT CONFIG="" ADW="sdlc"` signature so the chain can be picked as the fourth argument, e.g. `simple-sdlc`), `just sbx run agent my-run "..."` to hand off to the in-sandbox Pi orchestrator, `just sbx run cmd my-run 'tail -f run.log'` to look inside synchronously, `just obs sessions` / `just obs tail <adw_id>` to watch from outside, `just sbx manage harvest my-run` to bring the run's commits home as `refs/sandbox/<run-id>` inside `.sandbox/repos/<repo>.git` (never merging), and `just sbx lifecycle teardown my-run` (always explicit). The README distinguishes `<run-id>` (sandbox / VM name / public hostname) from `<adw_id>` (one factory run inside a box) and notes that `just sbx manage list` counts sandboxes while `just obs sessions` counts runs.
   - **(4) How it works** — the six phases plus the run record as the only shared state, "agents plus code — agent proposes, code disposes", typed envelopes and gates (a failure re-enters the same session as a correction, never a restart), the trace db (`adws/adw_data/sssf.db`, WAL, polled by the visualizer on 4600).
8. **Watch it run / command surface / Where it can still fail / footer** — kept, updated per the corrections. The command-surface tree drops the `inkwell` namespace and lists the `obs` recipes now shipped (sessions, phases, tail, procs, rosters, ui). The "two ports" caption is re-framed ("your app on a public port, the agent view auth-gated on a private one") and the `just obs rosters` recipe is added to the quick reference.

## Accuracy notes (where the README was wrong before)

The spec captures these corrections explicitly; the README now reflects them:

- **The in-sandbox orchestrator is Pi, not Claude Code.** `just sbx run agent` hands off to a resumable Pi session; Claude Code only runs on the host (`just local cc` / `just sbx orch cc`). The old "resumable Claude Code session" line is replaced.
- **`just sbx lifecycle execute` signature.** Prompt is the **second** argument and ADW chain is the **fourth** (`RUN_ID PROMPT CONFIG ADW`); the README shows the real signature, not the inverted one in the task prompt.
- **Target-mode harvest.** In target mode, run commits land as `refs/sandbox/<run-id>` inside a bare cache of your app repo at `.sandbox/repos/<repo>.git`, with the bundle at `.sandbox/runs/<run-id>.bundle`. The factory repo's refs are never touched.
- **`checks:` accepts both shapes.** The hello roster's inline caveat claiming the map form breaks `quality.py` is a stale comment from before spec `4e0c9038_quality-checks-map-form.md`; `quality._load_checks` now accepts both the compact map and the explicit list. The README states both forms work.
- **Roster count and `SSSF_CONFIG`.** Six rosters ship (`sssf.config.yaml`, `sssf.hello.config.yaml`, `sssf.deepestseek`, `sssf.frontier`, `sssf.open-weights`, `sssf.top-speed`). The active roster is selected by the `SSSF_CONFIG` env var (default `adws/adw_sssf_config/sssf.config.yaml`).
- **`apps/inkwell` is no longer vendored.** The old setup line `cd apps/inkwell && bun install`, the `just inkwell run/dev/test` recipes, and the "30 tests green = the payload works" line are removed. The `just inkwell` namespace still exists in the justfile but its recipes point at a path that is no longer vendored, so it is dropped from the command-surface section.

## How to verify

The spec's "Builder verification checklist" is the check the README was scored against:

```bash
# 1. Every recipe named in the README exists
just --list
just sbx
just sbx lifecycle
just sbx manage
just sbx run
just adw
just obs
just local

# 2. None of the stale content survives
grep -nE 'apps/inkwell|just inkwell|^.*bun install$|Claude Code session' README.md   # should return nothing inside the sandbox-flow sections

# 3. The hello-server example matches the shipped roster
grep -A4 '^app:' adws/adw_sssf_config/sssf.hello.config.yaml

# 4. The diff scope
git diff --stat   # README.md plus specs/b01e2809_readme-generalized-factory.md only

# 5. Visual check — does the README walk end to end
grep -n '## ' README.md   # should show the new section list including 'The app contract' and 'Set up a new app and develop in a sandbox'
```

## Out of scope

No code, tests, config, or other docs (`app_docs/`, other `specs/`) were touched. The chain's commit phase owns the commit; this run leaves the working tree dirty for that.
