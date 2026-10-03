# Plan: continue session aff7bbd0's build — verify, live-gate, finish (do NOT re-implement)

## Why this plan exists

Session `aff7bbd0`'s build phase (implementing `specs/aff7bbd0_sandbox-pi-model-parity.md`)
was killed mid-run — exit 143 (SIGTERM, harness timeout at ~338s). Its dying act was
fighting a **test-harness artifact**: it overrode `HOME` to test `pi_mirror.py` substitution
logic, which made `uv` lose its cache and hang. **That was not a code bug.**

This plan's job is to RESUME, not restart. The implementation is already in the working
tree, uncommitted, and — as of this plan's writing — independently re-verified.

## Verified current state (planner re-ran these; treat as ground truth)

All seven change items from the spec are implemented:

1. `sandbox_mount/host/pi_mirror.py` (new, PEP-723/uv/pyyaml) — **all three subcommands
   pass right now**:
   - `models` → 5 providers (`deepseek`, `kimi-coding`, `minimax-cn`, `zai`,
     `zai-coding-cn`), every model carries all four cost keys, every provider has an
     apiKey, both api flavors present (`openai-completions` + `anthropic-messages`).
   - `settings` → exactly `defaultProvider`/`defaultModel`/`defaultThinkingLevel`
     (`zai/glm-5.3-flash`), no `packages`.
   - `config --base adws/adw_sssf_config/sssf.config.yaml` → valid YAML, every one of
     the 5 agents has an explicit `model:`; only `builder`/`scout` (no configured model)
     warn-and-substitute the host default — the spec'd behavior.
2. `fill.just` — ships models.json/settings.json (0600) and `/home/exedev/sssf_config.yaml`
   (0644) over ssh stdin; fails loudly if `pi_mirror.py models` fails. NOTE: it reads
   `ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"` instead of the
   spec's `{{config}}` because imported module scope cannot see the root justfile's
   variable — same env var, same fallback, behaviorally equivalent. Deliberate, keep it.
3. `provision.sh` — step 4 keeps a FILL-shipped registry, falls back to the OpenRouter
   template with a loud warning; step 8b (Claude onboarding) deleted; summary renumbered.
4. `run/mod.just` — agent lane is `pi -p --session-id $SID`; sentinel machinery deleted
   (verified: zero `agent-started` references remain repo-wide; `harvest.just`'s comment
   that mentioned it was also updated).
5. `execute.just` — empty CONFIG defaults to `/home/exedev/sssf_config.yaml` with a
   remote presence-check that fails with "run fill first".
6. `setup.just` — gate C pings each roster model via
   `timeout 180 pi -p --no-tools --provider P --model M` inside the sandbox; gate D runs
   the live call on the roster's `defaults.model` plus a four-cost-key shape check and a
   per-roster-model non-zero-input-rate check; gate E is per-provider credential presence
   (jq on the sandbox's models.json). Exit codes 2/3/4 map to C/D/E.
7. Comment touch-ups — `orch/mod.just`, `create.just`, `execute.just` done. Grep confirms
   no stale "Claude" claims remain in `just/sandbox/mod.just` or the root `justfile`
   (the one `justfile:7` hit is a factual note about host binaries — leave it).

Static parse: `just --list`, `just --list sbx`, `just --list sbx::run`,
`just --list sbx::lifecycle` all exit 0.

Uncommitted working tree (all expected, do not revert):
`M sssf.config.yaml, create.just, execute.just, fill.just, setup.just, harvest.just,
orch/mod.just, run/mod.just, provision.sh` + `?? sandbox_mount/host/pi_mirror.py`
(+ the two `specs/*sandbox-pi-model-parity.md` files).

## Work remaining (in order)

### 1. Housekeeping — confirm the killed run left nothing behind

- `pgrep -af 'uv run|pi_mirror' || true` — kill anything still hung from the 143.
- Do NOT `git checkout` / `git clean` anything. The tree IS the work.

### 2. Final self-review (minutes, not hours)

- Re-read `git diff just/sandbox/lifecycle/setup.just` against spec item 6 — the one
  thing the spec flagged "verify during implementation": gate D's jq path
  `.providers[].models[].cost` must match the generator's schema. Planner already
  confirmed the generator emits the `{"providers": ...}` wrapper, so the jq path is
  correct; just eyeball it once.
- `git diff --stat` — the 9 modified + 1 new file list above; nothing more, nothing less.

### 3. Live verification — the spec's Verification items 2–5 (the real remaining work)

`OPENROUTER_PROVISIONING_KEY` is set in `.env` (planner confirmed presence, not value).
Run, in order:

1. `just sbx mount test-pi-mirror` — chains create → fill → setup → observe. All five
   gates must pass. **Watch gate C hardest**: it is the first live exercise of the
   `anthropic-messages` providers (`kimi-coding/k3`, `minimax-cn/MiniMax-M3`) — the spec's
   named risk. If pi rejects a provider block or a call fails, the fix belongs in
   `pi_mirror.py`'s emitted field shape, NOT in the gate. If `deepseek/deepseek-flash`
   or `zai/glm-5.3` fails too, suspect credentials/baseUrl, again in the generator.
2. Session resume: `just sbx run agent test-pi-mirror "remember the number 42, reply STORED"`
   then `just sbx run agent test-pi-mirror "what number?"` — second turn must answer 42.
3. Execute default: `just sbx lifecycle execute test-pi-mirror "add a one-line comment to README"`
   (no CONFIG arg) must run against `/home/exedev/sssf_config.yaml`;
   `just sbx run cmd test-pi-mirror "grep -c 'model:' /home/exedev/sssf_config.yaml"`
   shows the pre-filled models.
4. `just sbx lifecycle teardown test-pi-mirror` — completes; OpenRouter revoke path
   untouched (expect recorded `spend` = $0 on this direct-provider run; that is the
   documented consequence, not a failure).

If the sandbox cannot be mounted from this environment (no exe.dev egress, provisioning
key rejected), that is an environment limitation, not a code failure: re-run the static
checks (`just --list` ×4 + the three `pi_mirror.py` subcommands piped to
`python3 -c 'import json,sys; ...'` / a YAML parse — NEVER print the `models` output, it
contains live keys), say so explicitly in the report, and leave the tree ready.

### 4. Secret hygiene while verifying

- Never `cat` / echo `/home/exedev/.../models.json` content or `pi_mirror.py models`
  stdout — pipe into a parser that prints only provider names/counts.
- Scratch output to `/tmp`, never into the repo.

### 5. Finish

- Emit the `BuildOutput` JSON per the build contract: summary, `changed_files` (the 9
  modified + 1 new + 2 spec files if the harness wants them listed), and a commit
  message for the implementation, e.g.
  `Mirror host pi model set into sandboxes and switch the in-sandbox agent lane to pi`.

## Out of scope

- Re-implementing anything already in the diff.
- Changing `adws/adw_sssf_config/*.yaml`, `adw_modules/agent_pi.py`, the run-record
  schema, or the OpenRouter mint/teardown/reap machinery (spec: deliberately unchanged).
- Committing directly, unless the build contract for this session says the builder
  commits (the aff7bbd0 contract did not — it emits `commit_message`).
