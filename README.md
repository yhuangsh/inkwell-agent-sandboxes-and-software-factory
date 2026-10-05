# Factory In A Box

> **The software factory and the throwaway sandbox it runs in — bring your own app.**
> For engineers who want agents shipping code without a human in the loop.

📺 Watch this video to get the full breakdown of this codebase: **[Factory In A Box on YouTube](https://youtu.be/SEI_qIW4o2c)**

<p align="center">
  <img src="images/09_factory_in_a_box.png" alt="The software factory and a throwaway exe.dev VM nested around a mounted app, watched from the host" width="850">
</p>

Three things are separate here, and that separation is the whole design. **The factory** (this repo) is deterministic Python owning the graph, with coding agents as bounded phases inside it. **Your app** is any public git repo you bring, carrying a `sssf.app.yaml` manifest at its root. **The sandbox mount system** stands both up on a disposable VM in about 10 measured seconds. The factory repo contains **no app code** — the only per-app inputs are one roster file in `adws/adw_sssf_config/` and the LLM API keys you set in `.env`. **The point is the loop that ships your app without you in the middle.**

You can get value from this repo two ways, and both are first-class:

- **Run it.** Mount a throwaway VM, point the factory at a task, and watch agents ship code in isolation. Follow [Install](#install), then [Set up a new app and develop in a sandbox](#set-up-a-new-app-and-develop-in-a-sandbox).
- **Read it.** Study a working out-of-the-loop system: the primitives, the credential boundary, the trace pipeline. You need almost nothing installed. Jump to [Who commands what](#who-commands-what) and [Watch it run](#watch-it-run).

<p align="center">
  <img src="images/19_factory_in_a_box_titled.png" alt="Factory In A Box: an idle out-sandbox orchestrator on your machine hands a prompt across the boundary to an in-sandbox orchestrator that drives the ADW agents; the software factory is agents plus code" width="800">
</p>

---

## Install

### Agentic Install

```bash
claude               # boot Claude Code in the repo root
/install             # set up toolchain, verify .env, then run the preflight
/prime               # orient on all three layers (out-loop orchestrator, in-loop orchestrator, software factory), check live state
```

`/install` and `/prime` live in `.claude/commands/`. `/install` checks the toolchain, verifies `.env`, and runs the `just sbx manage doctor` preflight without starting anything. `/prime` then walks the agent through the command surface, the specs, and the measured gotchas.

Once oriented, you operate the whole system by talking to the agent. Two skills carry the knowledge, so you describe intent and the agent runs the right recipes:

- **`/sssf-sandbox-orchestrator`** drives the out-of-sandbox loop from plain English: mount a box, put work in, watch it, fan out best-of-N, harvest the winner, tear down. Thin skill, fat recipes: every action it takes is a `just sbx` command you could type yourself.
- **`/sssf`** drives the factory from inside a box: create, run, and observe the ADWs, and manage the agent roster.

### Manual Install

```bash
cp .env.sample .env                  # optional overrides plus the LLM API keys FILL provisions into each sandbox as app/.env
just sbx manage doctor               # five-check preflight: ssh, helpers, provisioner, roster keys, adw layer
```

There is no app-dependency step: your app is its own repo, cloned inside the sandbox by FILL. Set only the provider keys the active roster's models need — FILL fails fast and names the missing ones.

### Required Tech

Every resource this system leans on, what it does, and whether you actually need it. The right two columns matter: **running the full loop** asks for a bit of setup, but **reading and understanding** the system asks for almost nothing.

| Tech | Role in the system | Run the loop | Just read + observe |
|---|---|---|---|
| [`git`](https://git-scm.com) | clone the repo; the factory commits its own work | required | required |
| [`bun`](https://bun.sh) | serves the observability UI, and builds the visualizer; your app's own runtime is bootstrapped inside each sandbox by its manifest | required | optional (only to boot the UI locally) |
| [`uv`](https://docs.astral.sh/uv/) | runs the PEP-723 Python ADW scripts and the manifest probes | required | not needed |
| [`just`](https://just.systems) | the whole command surface | required | helpful (to read the recipes) |
| [exe.dev account](https://exe.dev) | the disposable VMs the factory runs inside | required to mount | not needed |
| [Pi](https://github.com/badlogic/pi-mono) + [Claude Code](https://claude.com/claude-code) | the coding agents | Pi is installed/upgraded to registry-latest by provision; Claude Code is only needed on the host for `just local cc` / `just sbx orch cc` | not needed |

One credential is the entire reason the sandbox is safe: the **exe.dev account** lives only on your host. Any LLM provider keys you declare in `.env` are carried into each sandbox by FILL, written 0600 to `app/.env`, and read by pi's built-in providers. The same path carries one optional app-repo git token (`APP_REPO_GIT_TOKEN`) when your app repo is private. Everything else is a fast, free toolchain install. If you only want to understand the design, clone the repo and read: no account, nothing to spend.

---

## Why this exists

<p align="center">
  <img src="images/15_out_of_the_loop.png" alt="In the loop, every lap pulls you back in; out of the loop, the agent run loop orbits and you just read it" width="780">
</p>

A system that needs you at every step does not scale, and you become the key-man risk in your own factory. The goal is the right side of that diagram: the loop orbits, you read the trace. Isolation is what makes it safe to let go.

<p align="center">
  <img src="images/13_agent_in_the_box.png" alt="Agent out reaches through the wall into your environment; agent in lives in the same room as the codebase" width="780">
</p>

The controversial call, stated plainly: **the coding agent runs inside the sandbox**, not outside it driving a remote shell. Pi is installed on the VM by the provisioner, in the same room as the codebase. The host keeps only a thin orchestrator and two credentials that never leave.

---

## Who commands what

<p align="center">
  <img src="images/11_who_commands_what.png" alt="Nested command tiers: the out-sandbox orchestrator manages sandboxes, the in-sandbox orchestrator runs the factory, ADW agents do the work" width="800">
</p>

Three command tiers, and each one commands only the tier inside it:

| Tier | Lives | Does |
| --- | --- | --- |
| **Out-sandbox super orchestrator** | your machine | mounts, fills, observes, harvests, tears down sandboxes |
| **In-sandbox orchestrator agent** | the VM, a resumable pi session | receives delegated work, launches the factory, watches it, reports |
| **ADW agents** | bounded phases inside the factory | scout, plan, build, review, document |

<p align="center">
  <img src="images/12_tier_command_surface.png" alt="Each tier has one command surface: just sbx mount/execute/teardown, then just adw sdlc, then the agent phases" width="780">
</p>

Work crosses the boundary on one of two paths, and the difference is who pulls the trigger inside:

| Path | Verb | Mechanism |
| --- | --- | --- |
| **Direct** | a command | `just sbx lifecycle execute` detaches the factory process itself: reproducible, pid-tracked, zero orchestration tokens |
| **Agent-mediated** | a delegation | `just sbx run agent` briefs the in-sandbox orchestrator, and *it* launches the factory: judgment at the kickoff, conversational, resumable |

Every delegation opens with the equip line, so the in-box agent routes instead of improvising:

```bash
just sbx run agent <id> "If you have not already: READ and EXECUTE .claude/skills/sssf/SKILL.md. Then: <work>"
```

<p align="center">
  <img src="images/21_one_orchestrator_many_sandboxes.png" alt="One out-sandbox orchestrator (x1) on your machine commands many agent sandboxes (xN), each running its own in-sandbox orchestrator over the scout, plan, build, test, review software factory" width="780">
</p>

---

## The app contract

The factory ships nothing app-specific. **An app is any public git repo with a `sssf.app.yaml` manifest at its root.** The manifest is how you tell a blank exeuntu VM what your app needs — without adding a line to this repo:

```yaml
# sssf.app.yaml — lives at the root of YOUR app repo.
runtime: bun            # bun | node | uv | none — CDN-bootstrapped toolchains, never apt
install:                # shell commands run once at provision, from the app root
  - bun install
build: []               # e.g. ["bun run build"]; [] for interpret-and-serve apps
serve:                  # optional — OBSERVE's app lane; no serve: means a library/CLI, skipped not failed
  command: bun --hot server.ts   # --hot = live reload during development: Bun re-imports the module graph without restarting the server
  port: 4501            # the ONE port the exe.dev proxy exposes anonymously
  health_path: /        # OBSERVE curls https://<host><health_path> for 200
checks:                 # optional — the SDLC quality gate, run from the app root
  test: [bun, test, server.test.ts]   # map form: <name>: <argv>
```

`checks:` accepts two shapes, and both work: the compact **map** (`test: [bun, test, server.test.ts]`, defaulting to `area: backend`, `operation: build`, `timeout_seconds: 120`) and the explicit **list** of `{name, area, operation, argv, timeout_seconds}` mappings.

The per-app input that lives *in this repo* is a roster file in `adws/adw_sssf_config/`. Its one app-specific block names the repo and the mount point:

```yaml
app:
  repo: https://github.com/<owner>/<app-repo>.git   # public, or private with APP_REPO_GIT_TOKEN in .env
  ref: main                 # optional: branch/tag/sha, default remote HEAD
  path: target              # mount point inside the factory clone
  manifest: sssf.app.yaml   # optional override; default sssf.app.yaml
```

With `repo` set (target mode), FILL clones your app into `~/app/<path>` on the VM, the run branch `sbx/<run-id>` and every ADW commit live on that clone, and HARVEST bundles from it — the factory clone stays byte-identical across apps. Without `repo`, the payload is vendored in the factory clone (legacy compat).

**The shipped worked example is [`hello-server`](https://github.com/yhuangsh/hello-server.git)** — a toy app whose manifest declares exactly the shape above: bun runtime, `bun install`, `serve` on port 4501, and a `checks.test`. Its roster is [`adws/adw_sssf_config/sssf.hello.config.yaml`](adws/adw_sssf_config/sssf.hello.config.yaml), and it is the repo you can mount end to end with zero factory edits.

Two graceful fallbacks: a repo with **no manifest** but a `package.json` gets `bun install` at provision; a manifest with **no `serve:` block** has its app lane skipped, not failed.

## The factory

<p align="center">
  <img src="images/01_factory_spine.svg" alt="The factory spine: a deterministic ADW script sequencing plan, build, and test phases with agents as bounded nodes" width="750">
</p>

Twelve ADWs (AI Developer Workflows) under `adws/`, each a thin `uv run` script whose docstring is its chain: `adw_simple_sdlc` runs plan, build, test, review, document with three separate commits. Typed envelopes carry context between phases; gates validate every claim, and a failure re-enters the same session as a correction, never a restart. **Agent proposes, code disposes.**

<p align="center">
  <img src="images/value/03_core_four.png" alt="An agent is four things: a model, a harness, tools, and a prompt, wired around a central agent node" width="750">
</p>

Under every phase is the same primitive: an agent is a model, a harness, tools, and a prompt. The factory holds those four constant and swaps only the prompt and the model per phase. Staffing is one config file, swappable per run: six rosters ship in `adws/adw_sssf_config/` — the cheap default (`sssf.config.yaml`), the frontier roster, pure DeepSeek, open-weights, top-speed, and `sssf.hello.config.yaml`, the per-app worked example. Every model is `provider/id`, resolved against pi's built-in provider catalog, so the same ids work on your laptop and inside every box.

The active roster is chosen by the `SSSF_CONFIG` env var (default `adws/adw_sssf_config/sssf.config.yaml`); set it in `.env` or pass a path per run.

The factory has its own standalone codebase at [disler/super-simple-software-factory](https://github.com/disler/super-simple-software-factory), the skill that stamps it into any repo. This repo just runs it.

## The sandbox

<p align="center">
  <img src="images/16_six_phase_run.png" alt="The run end to end: create, fill, setup on the host, execute inside, observe and teardown from the host, ~10s total cold mount" width="780">
</p>

Six phases take a blank exe.dev VM to a health-checked, running factory in about 10 measured seconds: create, fill, setup, execute, observe, teardown. Every phase is a `just` recipe a human could type; the run record on disk is the only state they share, so any crash leaves teardown a handle.

Setup runs a **host-streamed provisioner**: the same `provision.sh` as your host checkout (`bash -s` over ssh stdin, never the VM's copy), so provisioner and gates can never skew. It bootstraps bun, just, and node+npm from their own CDNs, installs **pi at registry-latest**, then runs your manifest's `install:`/`build:` from the app root. **apt never.**

<p align="center">
  <img src="images/10_credential_boundary.png" alt="The credential boundary: the exe.dev account never leaves the host; LLM provider keys are shipped into each sandbox as app/.env; a sandbox cannot mount sandboxes" width="750">
</p>

The factory clone ships to the VM as the toolbelt; your app is its own clone. What a sandbox cannot do is *use* the orchestration half, because the exe.dev account never leaves the host. Each sandbox instead gets its LLM provider keys as `app/.env`, shipped by FILL and read by pi's built-in providers. **One level of nesting, enforced by credentials rather than by deleting files.**

<p align="center">
  <img src="images/17_best_of_n.png" alt="Best-of-N: one prompt fans out to three software factories and the results come back ranked" width="750">
</p>

Fan-out is a loop over configs: one prompt, N rosters, N boxes. Teardown is never automatic, and harvest never merges: in target mode a run's commits come home as `refs/sandbox/<run-id>` inside a bare cache of your app repo (`.sandbox/repos/<repo>.git`), parked for a human to compare and choose the winner.

---

## Set up a new app and develop in a sandbox

<p align="center">
  <img src="images/20_command_tiers_pipeline.png" alt="A prompt on your machine wakes the idle out-sandbox orchestrator, crosses into the agent sandbox where the in-sandbox orchestrator runs the ADW agents in sequence: scout, plan, build, test, review, with a feedback loop back" width="780">
</p>

The main flow, top to bottom. Every command is a `just` recipe you could type by hand.

**Lane mental model.** Steering and inspection are not the factory — keep the lanes apart:

- **`just sbx run agent` / `just sbx run cmd` — steering and inspection.** `run agent` is ONE pi turn: no chains, no gates, no commits; its edits stay uncommitted working-tree changes in the sandbox. `run cmd` is the synchronous generic escape hatch that prints stdout.
- **`just sbx lifecycle execute` — the factory.** The full SDLC with gates, reviews, and commits to the run branch `sbx/<run-id>`.
- **`just sbx manage harvest` — bringing the run's commits home.** Safe and non-destructive; it never merges.
- **`just sbx mount` / `just sbx lifecycle teardown` — the only times a sandbox is created or destroyed.** A fresh mount is for a clean box, never needed just to test a change.

The app process starts once at `observe` and does not hot-reload unless the app's own manifest opts in — see the `serve:` example in [The app contract](#the-app-contract).

### 0. Prerequisites

```bash
# an exe.dev account, with ssh access (this is what the doctor pings)
ssh exe.dev whoami

# your credentials and config
cp .env.sample .env               # set the LLM API keys the roster's providers need
just sbx manage doctor            # must end with: sbx doctor: OK
```

`doctor` runs five checks: ssh exe.dev reachable, the run-record helper runs, the provisioner is present, the active roster's provider keys are set, and the adw layer resolves.

### 1. Set up a new app

Make your app repo **public** (zero config, clones unauthenticated) **or private** (set a token), and put a `sssf.app.yaml` at its root (the schema is in [The app contract](#the-app-contract); [`hello-server`](https://github.com/yhuangsh/hello-server.git) is the worked example). Then give the factory one roster naming it:

```bash
# start from the shipped hello-server example and edit the `app:` block
cp adws/adw_sssf_config/sssf.hello.config.yaml adws/adw_sssf_config/sssf.myapp.config.yaml

# in sssf.myapp.config.yaml set:
#   app:
#     repo: https://github.com/<you>/<your-app>.git
#     ref: main
#     path: target
#     manifest: sssf.app.yaml

# in .env, point the factory at your roster
echo 'SSSF_CONFIG=adws/adw_sssf_config/sssf.myapp.config.yaml' >> .env

just sbx manage doctor            # re-check: now validates YOUR roster's provider keys
```

**Private app repo.** If your repo is private, set `APP_REPO_GIT_TOKEN` in `.env` to a git personal access token with read access to it (the factory repo itself stays public and credential-free). FILL ships the token to `app/.env` (0600) on the VM through the same stdin-only credential path as the LLM keys, and the clone authenticates through an ephemeral `GIT_ASKPASS` helper, so the stored remote URL never carries the token. A private repo mounted without the token fails FILL with a named error telling you to set `APP_REPO_GIT_TOKEN`. Never put the token in a roster — rosters are committed.

### 2. Mount

```bash
just sbx mount my-run             # create -> fill -> setup -> observe (~10s), prints the run id and URLs
```

`mount` chains four of the six phases and stops at `observe` on purpose — teardown is never chained. FILL clones your app to `~/app/target` and creates the run branch `sbx/my-run` on it; SETUP provisions and then runs the five-assertion health gate:

- **A** git integrity — factory HEAD + target HEAD match the run record, factory tree clean
- **B** pi is current (== registry latest) and `--list-models` is non-empty
- **C** a roster ping answers through the sandbox's own pi
- **D** a live call reports non-zero cost
- **E** every roster provider has its env key

OBSERVE starts your app on the manifest's `serve.port` (**4501** for hello-server — the one anonymously exposed port) and the trace UI on **4600**, auth-gated to exe.dev users with VM access, then prints both URLs.

### 3. Develop

Put work in, watch it, bring it home, tear it down:

```bash
# run the factory INSIDE the sandbox — detached, records a PID, zero orchestration tokens
just sbx lifecycle execute my-run "add a /health endpoint"                  # default chain: sdlc
just sbx lifecycle execute my-run "add a /health endpoint" "" simple-sdlc   # pick a chain (arg 4)

# or hand off to the in-sandbox pi orchestrator and keep talking to it
just sbx run agent my-run "If you have not already: READ and EXECUTE .claude/skills/sssf/SKILL.md. Then: <work>"

# inspect synchronously — logs, git state, anything
just sbx run cmd my-run 'tail -f run.log'

# watch from outside
just obs sessions                 # the ADW runs inside your boxes
just obs tail <adw_id>            # live event stream for one factory run

# bring the run's commits home (safe, non-destructive, run any time)
just sbx manage harvest my-run    # -> .sandbox/repos/myapp.git refs/sandbox/my-run
git -C .sandbox/repos/myapp.git log --oneline --graph <base>..refs/sandbox/my-run

# tear it down (always an explicit human decision)
just sbx lifecycle teardown my-run
```

**`just sbx lifecycle execute` takes the prompt as the second argument and the ADW chain as the fourth** (`RUN_ID PROMPT CONFIG ADW`); `CONFIG` is the roster for a fan-out arm and defaults to the roster FILL shipped. Harvest never merges: it writes only `refs/sandbox/<run-id>` in the app repo's bare cache and never touches any branch you own.

Two handles, do not confuse them: **`<run-id>`** names the sandbox (it is also the VM name and the public hostname) and is what `just sbx ...` takes, while **`<adw_id>`** names one factory run inside that box and is what `just obs ...` takes. `just sbx manage list` counts sandboxes; `just obs sessions` counts the runs within them. A single box can host many ADW runs.

### 4. How it works

Four ideas carry the whole system:

- **Six phases, one run record.** create → fill → setup → execute → observe → teardown. Each is a standalone recipe; the run record on disk is the only state they share, so any phase can crash and teardown still has a handle. `mount` stops at observe; teardown is always explicit.
- **Agents plus code — agent proposes, code disposes.** Agents plan, build, review, and document; deterministic Python owns the sequencing, the test command, and the commits. A phase's claim is only true once a gate accepts it.
- **Envelopes and gates.** Typed envelopes carry context between phases; a gate validates every claim, and a failure re-enters the same session as a correction, never a restart.
- **One trace db.** Every phase, tool call, complete thought, and complete response streams into `adws/adw_data/sssf.db` (WAL, so reads never block writers). The visualizer on :4600 polls it.

---

## From zero to hero: your first sandbox run

The sections above are the *what* and the *why*. This is the whole loop typed once, end to end, on an app you create in the next five minutes. Every command is a `just` recipe you could type by hand; everything is copy-pasteable except the placeholders `<you>` and `<app>`.

### 1. Create the app repo on GitHub

```bash
gh repo create <you>/<app> --public --clone     # or --private — see below
cd <app>
```

A **public** repo clones unauthenticated, with zero config. A `--private` repo clones inside the sandbox only if `APP_REPO_GIT_TOKEN` is set in the host `.env`; the full story is the **Private app repo** paragraph in [Set up a new app and develop in a sandbox](#set-up-a-new-app-and-develop-in-a-sandbox).

Seed the repo with the four files of the [`hello-server`](https://github.com/yhuangsh/hello-server.git) shape:

`package.json`:
```json
{
  "name": "hello-server",
  "version": "0.1.0",
  "private": true,
  "scripts": { "start": "bun run server.ts" }
}
```

`server.ts`:
```ts
export function greet(name: string): string {
  return `hello, ${name}`;
}

if (import.meta.main) {
  const port = Number(process.env.PORT ?? 4501);
  Bun.serve({ port, fetch: () => new Response(greet("world") + "\n") });
  console.log(`hello-server on :${port}`);
}
```

`server.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import { greet } from "./server";

describe("greet", () => {
  test("greets by name", () => {
    expect(greet("sssf")).toBe("hello, sssf");
  });
});
```

`sssf.app.yaml`, at the repo root — the app contract, key by key, is [The app contract](#the-app-contract):
```yaml
runtime: bun
install:
  - bun install
build: []
serve:
  command: bun run server.ts
  port: 4501
  health_path: /
checks:
  test: [bun, test, server.test.ts]
```

```bash
git add -A && git commit -m "Seed app with sssf manifest" && git push
```

### 2. Write the roster

The one per-app input that lives *in this repo* is a roster file. Start from the shipped example and edit its `app:` block:

```bash
cp adws/adw_sssf_config/sssf.hello.config.yaml adws/adw_sssf_config/sssf.myapp.config.yaml
```

In `adws/adw_sssf_config/sssf.myapp.config.yaml`, set:

```yaml
app:
  repo: https://github.com/<you>/<app>.git
  ref: main
  path: target
  manifest: sssf.app.yaml
```

Then point the factory at your roster:

```bash
echo 'SSSF_CONFIG=adws/adw_sssf_config/sssf.myapp.config.yaml' >> .env
```

The roster also needs its providers' API keys in `.env` — `.env.sample` lists the allowlist, and FILL fails fast naming any missing one.

### 3. Verify prerequisites

```bash
just sbx manage doctor            # five checks; must end with: sbx doctor: OK
```

`doctor` runs five checks: ssh exe.dev reachable, the run-record helper runs, the provisioner is present, the active roster's provider keys are set, and the adw layer resolves. The exe.dev account and `ssh exe.dev whoami` are covered in [Install](#install).

### 4. Mount

```bash
just sbx mount my-run             # create -> fill -> setup -> observe (~10s)
```

`mount` chains four of the six phases — **create → fill → setup → observe** — and stops at `observe` on purpose: teardown is never chained.

What happens inside:

- **create** boots a blank VM for the run.
- **fill** clones the factory to `~/app` and your app to `~/app/target` on the VM, opening the run branch `sbx/my-run` on the app clone.
- **setup** runs the **host-streamed provisioner** — the host checkout's `sandbox_mount/guest/provision.sh`, piped over ssh (`bash -s`, never the VM's own copy) — which bootstraps bun, just, and node+npm from their own CDNs and installs **pi at registry-latest**, then runs your manifest's `install:`/`build:`. **apt never.** Then it runs the five-assertion health gate:
  - **A** git integrity — factory HEAD + target HEAD match the run record, factory tree clean
  - **B** pi is current (== registry latest) and `--list-models` is non-empty
  - **C** a roster ping answers through the sandbox's own pi
  - **D** a live call reports non-zero cost
  - **E** every roster provider has its env key
- **observe** starts your app on the manifest's `serve.port` (**4501** — the one anonymously exposed port) and the trace UI on **4600**, auth-gated to exe.dev users with VM access, then prints both URLs:

```
  app  https://<vm>.exe.xyz/
  obs  https://<vm>.exe.xyz:4600/
```

`mount` ends by printing the run id and the four next-step commands:

```
mounted: my-run
  execute: just sbx lifecycle execute my-run "<prompt>"
  agent:   just sbx run agent my-run "<prompt>"
  harvest: just sbx manage harvest my-run
  destroy: just sbx lifecycle teardown my-run
```

### 5. Develop

```bash
just sbx lifecycle execute my-run "add a /health endpoint that returns {\"status\":\"ok\"}"
```

The recipe is `execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA`: the prompt is argument 2, and the ADW chain is **argument 4**, so picking a chain means an empty-string placeholder for CONFIG:

```bash
just sbx lifecycle execute my-run "add a /health endpoint" "" simple-sdlc
```

(`sdlc` is the default; the chain names are `just adw` recipes, e.g. `simple-sdlc`.)

`execute` is **detached**: it returns and records a PID, one SDLC per box at a time, and `run.log` is truncated on every execute.

Monitor it:

- `just sbx run cmd my-run 'tail -f run.log'` — the synchronous escape hatch.
- the trace UI on `:4600`, already running from `observe`.
- the trace db lives **inside the sandbox** at `~/app/adws/adw_data/sssf.db`. The `just obs` recipes (`just obs sessions`, `just obs phases <adw_id>`, `just obs tail <adw_id>`) read `adws/adw_data/sssf.db` relative to the working directory, so querying the box's db from the host goes through the escape hatch:

```bash
just sbx run cmd my-run 'just obs sessions'
just sbx run cmd my-run 'just obs phases <adw_id>'
```

Two handles, do not confuse them: **`<run-id>`** names the sandbox and is what `just sbx ...` takes, while **`<adw_id>`** names one factory run inside that box and is what `just obs ...` takes. The full distinction is in [Set up a new app and develop in a sandbox](#set-up-a-new-app-and-develop-in-a-sandbox).

### 6. Harvest

```bash
just sbx manage harvest my-run
```

In target mode (your roster's `app.repo` is set), harvest bundles the run branch's commits off the VM and fetches them into a bare cache of your app repo at `.sandbox/repos/<app>.git` as `refs/sandbox/my-run`, leaving the bundle at `.sandbox/runs/my-run.bundle`. It prints the two read commands:

```bash
git -C .sandbox/repos/<app>.git log --oneline --graph <base>..refs/sandbox/my-run
git -C .sandbox/repos/<app>.git diff <base>..refs/sandbox/my-run
```

Harvest never merges and never touches a branch you own — safe to run any time, idempotent on re-run.

### 7. Teardown

```bash
just sbx lifecycle teardown my-run
```

Teardown is always an explicit human decision, never chained — the reason `mount` stops at `observe`. Its order is **artifacts → harvest → destroy → close the run record**; harvest is on by default here too, and a harvest failure **aborts before destroy**. The only flag is `--no-harvest`.

### 8. Iterate

Re-run work on the same box with another `just sbx lifecycle execute`, or refresh the code with a re-fill:

```bash
just sbx lifecycle fill my-run            # idempotent: fetches, ff-only, never resets over run commits
just sbx lifecycle fill my-run <sha>      # pin the FACTORY clone to a sha
```

Re-fill switches to the run branch `sbx/my-run` and advances it ff-only, never re-creating it. The optional `<sha>` pins the **factory** clone; your **app** clone is pinned by the roster's `app.ref`.

The loop is one line: edit prompt → execute → watch → harvest → teardown. The command tiers are in [Who commands what](#who-commands-what); the observability surface is in [Watch it run](#watch-it-run).

---

## Watch it run

<p align="center">
  <img src="images/14_observe_from_outside.png" alt="Observe from outside only: the out-sandbox orchestrator reads the app and agent view but never reaches in; traces flow up from the agents" width="780">
</p>

You watch from outside; you never reach in. Every phase, tool call, complete thought, and complete response streams into `sssf.db` as it happens (agents to sqlite to you, WAL so reads never block writers), and the visualizer polls it.

<p align="center">
  <img src="images/value/06_observability.png" alt="A swimlane of engineer, planner, and builder phases over time, every run recorded down into a sqlite store" width="750">
</p>

That trace is also the answer for the read-only audience: you do not have to run anything to understand the system, because every run it ever did is recorded. Query `adws/adw_data/sssf.db` directly, or boot the UI.

<p align="center">
  <img src="images/18_two_ports.png" alt="One sandbox, two ports: your app on a public port, the agent view auth-gated on a private one" width="750">
</p>

Each sandbox exposes two ports: your app is public, the agent view stays auth-gated to you. Ship the app; keep the factory floor private.

```bash
just obs ui                 # boot the observability UI (server :4600 + vite dev)
just obs sessions           # recent runs
just obs tail <adw_id>      # live event tail
just obs rosters            # which rosters exist and who is in them
just sbx manage list        # every sandbox: state, VM alive
```

---

## The command surface

The namespaces answer *where the work happens*:

```
justfile
├── adw      the workflows: sdlc, simple-sdlc, build-test, scout … (runs IN a sandbox)
├── sbx      sandbox orchestration: mount, lifecycle, run, manage, orch (host-only)
├── obs      read the trace: sessions, phases, tail, procs, rosters, ui
└── local    boot an orchestrator agent on THIS machine: cc / pi / ipi
```

```bash
just sbx mount my-run                                      # blank VM → running factory, ~10s
just sbx run cmd my-run 'tail -f run.log'                  # look inside, synchronously
just sbx manage harvest my-run                             # commits home → refs/sandbox/my-run
just sbx lifecycle teardown my-run                         # human decision, always
```

`TREE.md` is the file-by-file map of the whole repo, grouped by layer, if you want the full territory.

---

## Where it can still fail

Every one of these was measured on live hardware, and each cost a debugging cycle:

- **A just module inherits nothing.** Not variables, not settings, not the working directory. Every module re-declares what it needs; each missing line fails in a different silent way.
- **`pi --list-models` exits 0 while printing "No models available."** Health checks assert on output, never `$?`.
- **A partial cost block drops the whole roster.** pi requires all four rate fields; miss one and every run reports $0.0000 while genuinely spending.
- **Never `apt` in the mount path.** About 35s per package from the `dal` region; bun and just come from their own CDNs in about a second.
- **An unsynced golden-VM clone produced 5,641 zero-byte files** and every naive check passed. Gates check content, not existence.

The deep list lives in `.claude/skills/sssf-sandbox-orchestrator/references/gotchas.md`.

---

## License

MIT — see [`LICENSE`](LICENSE).

---

## Master Agentic Coding

Want to a clear hands on guide to building your software factory?

Master tactical agentic coding patterns with [Tactical Agentic Coding](https://agenticengineer.com/tactical-agentic-coding?y=fctinbox).

Don't want to pay for stuff? No problem: Follow the [IndyDevDan YouTube channel](https://www.youtube.com/@indydevdan) to improve your agentic coding advantage.

---

Stay Focused and Keep Building

- IndyDevDan
