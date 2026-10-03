# Plan: sandboxes run pi on the host's own model set, with a per-sandbox sssf config

## Goals (from the request)

1. Each sandbox uses **pi** as the agent (no Claude Code lane inside sandboxes).
2. Each sandbox's pi agent is provisioned with **the same model set as the host's pi agent**.
3. Each sandbox has **its own `sssf_config.yaml`** with agent models pre-filled and validated against what the host pi agent supports.

## Current state (what we found)

- **In-sandbox agent lanes.** The ADWs (`just adw …` → `adws/adw_modules/agent_pi.py`) already run pi. The one remaining Claude lane inside sandboxes is `just sbx run agent` (`just/sandbox/run/mod.just`), which drives `claude -p` over the exe.dev gateway with a `--session-id`/`--resume` sentinel flow. `provision.sh` step 8b pre-answers Claude's interactive onboarding.
- **Sandbox pi registry.** `provision.sh` step 4 writes `~/.pi/agent/models.json` from the hardcoded OpenRouter-only template `sandbox_mount/guest/models.json.tmpl`, baking in the minted OpenRouter runtime key. So sandbox pi currently exposes `openrouter/*` models, NOT the host's set.
- **Host pi state** (all verified on this machine):
  - `~/.pi/agent/models-store.json` — the full catalog, keyed by provider (`deepseek`, `zai`, `kimi-coding`, `minimax-cn`, `zai-coding-cn`). Every model entry carries `api` (`openai-completions` or `anthropic-messages`) and `baseUrl`, plus `cost`, `contextWindow`, `maxTokens`, `reasoning`, `input`. No secrets in this file.
  - `~/.pi/agent/auth.json` — `{provider: {type: "api_key", key: "…"}}`. **Contains the operator's personal provider keys.**
  - `~/.pi/agent/settings.json` — `defaultProvider: zai`, `defaultModel: glm-5.3-flash`, `defaultThinkingLevel: high` (plus host-only `packages` that must NOT be shipped).
- **Rosters.** `adws/adw_sssf_config/sssf.config.yaml` (and siblings) already name host-pi providers (`kimi-coding/k3`, `zai/glm-5.3`, `minimax-cn/MiniMax-M3`, `deepseek/deepseek-flash`) — the sandbox is the laggard that cannot resolve them. `adw_modules/agent_pi.py:resolve_model()` resolves `provider/id` against `pi --list-models`, so once the sandbox registry mirrors the host, the same roster strings work unchanged.
- **Config flow.** `just sbx lifecycle execute RUN_ID PROMPT CONFIG="" …` appends `--config` remotely; setup gate C takes the same CONFIG argument to ping roster models. Gate A requires a **clean git tree**, so a per-sandbox config must NOT be written inside `app/` on the VM.
- **Run record schema is closed** (`run_record.py` rejects unknown keys) — do not add fields; use fixed path conventions instead.
- pi CLI (verified via `pi --help`): `--session-id <id>` "use exact project session ID, **creating it if missing**" — so the claude-style first-turn/subsequent-turn sentinel is unnecessary with pi.

## Deliberate design decision: the credential boundary moves

Today only the disposable OpenRouter runtime key crosses to a sandbox. Goal 2 requires the sandbox to actually CALL the host's providers, and the only credentials for `deepseek`/`zai`/`kimi-coding`/`minimax-cn`/`zai-coding-cn` live in the host's `~/.pi/agent/auth.json`. So this change ships those personal provider keys into the sandbox's pi registry. That is a deliberate expansion, done with the same discipline as the runtime key: piped over ssh **stdin** (never argv, never logged), written `umask 077` / `chmod 600`, and noted in the header comments of every file that touches it. Sandboxes remain disposable; teardown still destroys the VM.

The OpenRouter mint/revoke machinery (`create.just`, `teardown.just`, `reap.just`, `doctor`) stays in place unchanged: it backs the template fallback path and its spend accounting. Known consequence to document in `fill.just`/`teardown.just` comments: on direct-provider runs the recorded OpenRouter `spend` will read $0, because spend no longer flows through that key. Per-run cost is still reported by pi itself (gate D proves the rate table works).

## Changes, file by file

### 1. NEW `sandbox_mount/host/pi_mirror.py` — the host-side mirror generator

PEP-723 script run with `uv run` (needs `pyyaml`; matches the repo's existing `uv run` pattern in `provision.sh` step 7). Stdlib-only is NOT possible here because config generation needs YAML. Three subcommands, all writing to **stdout** so `fill.just` can pipe them over ssh without temp files holding secrets:

- `uv run sandbox_mount/host/pi_mirror.py models`
  - Read `~/.pi/agent/models-store.json` and `~/.pi/agent/auth.json`; fail loudly (exit 1, stderr message) if either is missing.
  - Emit a pi user-registry document in the **template-proven schema** (`sandbox_mount/guest/models.json.tmpl` is the proof pi accepts it):
    `{"providers": {<name>: {"baseUrl": …, "api": …, "apiKey": <key from auth.json>, "models": […]}}}`.
  - Per provider: `baseUrl`/`api` from its model entries (verified uniform per provider on the host); refuse a provider with no auth.json entry (warn on stderr, skip it — a keyless provider in the registry would fail at call time anyway).
  - Per model: emit ONLY the fields the template proves out — `id`, `name`, `contextWindow`, `maxTokens`, `reasoning`, `input`, and a `cost` block with ALL FOUR of `input`/`output`/`cacheRead`/`cacheWrite` (default missing ones to `0`; a partial cost block fails pi schema validation and pi drops the ENTIRE roster — this is recorded in `setup.just` gate D's comments).
- `uv run sandbox_mount/host/pi_mirror.py settings`
  - Read host `~/.pi/agent/settings.json`; emit a minimal settings doc with ONLY `defaultProvider`, `defaultModel`, `defaultThinkingLevel`. Never copy `packages` (host npm extensions don't exist on the sandbox).
- `uv run sandbox_mount/host/pi_mirror.py config [--base <roster.yaml>]`
  - `--base` defaults to `adws/adw_sssf_config/sssf.config.yaml` (fill.just will pass the root justfile's `{{config}}` explicitly).
  - Load the base roster with pyyaml. Build the host's supported set from `models-store.json` as `provider/id` strings, plus the host default `defaultProvider/defaultModel` from settings.json.
  - For `defaults` and EVERY agent: resolve the model — keep the configured value if it is in the supported set; if missing or unsupported, substitute the host default and print a warning to stderr. Write the resolved value EXPLICITLY on every agent ("pre-filled": no agent relies on inheritance in the emitted file).
  - Copy every other key through untouched (`purpose`, `prompt_engineering`, `harness_engineering`, `writes`, `tools`, `thinking`, `color`, `protected_files`, `observability`, …) and emit YAML to stdout. Comments are lost — acceptable for a generated runtime artifact; put a generated-file banner comment at the top instead.
  - Exit non-zero if the base roster is unreadable or the supported set is empty.

### 2. `just/sandbox/lifecycle/fill.just` — ship the mirror and the per-sandbox config

After the existing `.env` write (keep it — it backs the template fallback), add a new section, same secret discipline as the `.env` write (`printf … | ssh "$HOST" 'umask 077 && cat > …'`, never argv):

1. `pi_mirror.py models` → pipe to `~/.pi/agent/models.json` on the VM (remote `mkdir -p "$HOME/.pi/agent"` first), `chmod 600`. If `pi_mirror.py models` exits non-zero, FAIL the fill with a message that the host pi agent has no readable catalog (`~/.pi/agent/models-store.json` / `auth.json` missing) — goal 2 cannot be met, and filling anyway would silently fall back to the OpenRouter template.
2. `pi_mirror.py settings` → pipe to `~/.pi/agent/settings.json`, `chmod 600`.
3. `pi_mirror.py config --base "{{config}}"` → pipe to `/home/exedev/sssf_config.yaml` (fixed ABSOLUTE path — do NOT use `$HOME` here: execute/setup build remote command strings through two quoting hops where `$HOME` expansion is fragile; `observe.just` already establishes that the exeuntu user is `exedev`). This file holds no secrets: `chmod 644`. `{{config}}` is the root justfile variable (`env_var_or_default("SSSF_CONFIG", …)`), which imported files share — so `SSSF_CONFIG=other.yaml just sbx lifecycle fill …` produces a matching per-sandbox config.
4. Echo one line per shipped file with mode/size via remote `stat -c "%a %s"` (same pattern as the existing `.env` proof), and one comment block stating the boundary change: host provider keys now cross; OpenRouter spend will read $0 on direct-provider runs.

### 3. `sandbox_mount/guest/provision.sh` — respect the shipped registry; drop Claude

- **Step 4 (pi models.json):** if `$HOME/.pi/agent/models.json` already exists (shipped by FILL), keep it and `say` so. Only when absent, fall back to the current template + runtime-key bake-in path, with a loud warning that the sandbox is on the OpenRouter fallback set, not the host's model set. Keep `sandbox_mount/guest/models.json.tmpl` in the repo for this fallback (the `doctor` check in `manage/mod.just` references it — leave both alone).
- **Step 8b (claude onboarding):** delete the whole step (goal 1 — pi is the in-sandbox agent; nothing runs `claude` inside a sandbox anymore). Renumber the summary to `9/9` wording as needed and drop the `claude --version` line from the summary (or keep it as informational if the binary happens to exist — builder's choice, but the onboarding step goes).

### 4. `just/sandbox/run/mod.just` — the `agent` lane becomes pi

- Rewrite the `agent` recipe's remote invocation from
  `ANTHROPIC_API_KEY=implicit ANTHROPIC_BASE_URL=https://llm.int.exe.xyz claude -p $FLAG --dangerously-skip-permissions $Q`
  to `pi -p --session-id $SID $Q` (run from `cd app` as today).
- `--session-id` creates the session if missing (verified in `pi --help`), so DELETE the `STARTED` sentinel machinery and the first-turn/subsequent-turn branch — one flag works for every turn. Keep reading `session_id` from the run record (CREATE still mints the UUID).
- Update the file header and the recipe comment: the lane is pi now; remove the Claude Code / exe.dev gateway explanation (that gateway stays only in `orch/mod.just`'s host-side `cc` lane, which is out of scope).

### 5. `just/sandbox/lifecycle/execute.just` — default to the sandbox's own config

- When CONFIG is empty, default the remote config path to `/home/exedev/sssf_config.yaml` (the file FILL guarantees). Presence-check it remotely (`ssh … test -f`) and fail with "run fill first" rather than silently falling back — a silent fallback to the repo default is exactly the drift this task removes. An explicit CONFIG argument still wins (fan-out with a pinned roster keeps working).
- Update the header comment: the three ways in are `run cmd`, `lifecycle execute`, and `run agent` — and the agent is pi, not Claude Code.

### 6. `just/sandbox/lifecycle/setup.just` — the gate follows the new reality

Keep the overall shape (provision → sentinel → gate; never destroy on failure). Changes inside the gate:

- **Default CONFIG:** when the argument is empty, use `/home/exedev/sssf_config.yaml` (same presence-check-and-fail posture as execute). Update the header comment that explains why CONFIG is an argument.
- **Assertion A (git integrity):** unchanged. (This is why the per-sandbox config lives at `/home/exedev/sssf_config.yaml`, outside `app/`.)
- **Assertion B (`pi --list-models` non-empty, reject "No models available"):** unchanged — it now proves the HOST-mirrored registry loaded.
- **Assertion C (roster ping):** stop curling OpenRouter. Parse `provider/id` values out of the config as today (the `awk` over `model:` lines, but WITHOUT `sed 's|^openrouter/||'` — the provider half is now the pi provider name), then ping each model THROUGH PI ITSELF inside the sandbox:
  `timeout 180 pi -p --no-tools --provider <p> --model <m> 'ping - respond with pong'`
  asserting non-empty output per model. This verifies credential, baseUrl, api flavor (`openai-completions` AND `anthropic-messages` both appear in the host catalog), and registry entry in one shot — which an OpenRouter curl never could for direct providers. Keep the per-model `pass/FAIL` lines and exit-2-on-failure contract.
- **Assertion D (pi reports real cost):** keep both halves, but run the live pi call on the config's `defaults.model` (parse it from the config; it is guaranteed present after goal 3's pre-fill) instead of the hardcoded `openrouter/deepseek/deepseek-v4-flash-0731`. Keep the rate-table `jq` check against `$HOME/.pi/agent/models.json` — the jq path changes from `.providers[].models[]` only if the generator's schema differs; it doesn't (same providers-wrapper schema as the template), so the existing check should survive verbatim. Verify during implementation.
- **Assertion E (credit):** the OpenRouter `limit − usage` reading is no longer meaningful when spend flows to direct providers. Replace it with a credential-presence check: every provider referenced by the config's models has a non-empty, non-`env:` `apiKey` in the sandbox's `models.json` (jq). Update the gate summary lines accordingly.
- The runtime key is still read for the template fallback path only; keep the "never echoed" discipline.

### 7. Comments/docs touch-ups (cheap, keeps the repo honest)

- `just/sandbox/mod.just` and root `justfile` headers: where they describe the sandbox agent as Claude, say pi.
- `just/sandbox/orch/mod.just`: the trailing comment pointing at `run agent` — update "drives Claude Code on the VM" to pi. The host-side `cc`/`pi` orchestrator lanes themselves stay (goal 1 scopes to sandboxes).
- `just/local.just`: unchanged (host/factory-level boot menu; `pi` lane already exists).

## What deliberately does NOT change

- `create.just` (OpenRouter runtime-key mint), `teardown.just` (spend capture + revoke), `manage/reap.just`, `manage/mod.just` doctor — the OpenRouter machinery remains the fallback path and its accounting.
- `adws/adw_sssf_config/*.yaml` on the host — the per-sandbox config is a GENERATED runtime artifact on the VM, not a new checked-in roster.
- `adws/adw_modules/agent_pi.py` — it already resolves against `pi --list-models`, which is exactly what the mirror feeds.
- The run record schema.

## Verification

1. **Static:** `just --list`, `just --list sbx`, `just --list sbx::run`, `just --list sbx::lifecycle` all parse (catches duplicate `set` lines / variable collisions in the imported phase files). `uv run sandbox_mount/host/pi_mirror.py models | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d["providers"]))'` prints the five host providers; same for `settings` and `config` (config output parses as YAML and every agent has an explicit `model:`).
2. **Full mount:** `just sbx mount test-pi-mirror` must pass all five gates — B proves the mirrored registry loaded, C proves every roster model answers through pi with the mirrored credentials, D proves pi reports non-zero cost, E proves credential coverage. Expect gate C to exercise both `openai-completions` and `anthropic-messages` providers.
3. **Agent lane:** `just sbx run agent test-pi-mirror "remember the number 42, reply STORED"` then `just sbx run agent test-pi-mirror "what number?"` — second turn must answer 42, proving `--session-id` resume works.
4. **Execute default:** `just sbx lifecycle execute test-pi-mirror "add a one-line comment to README"` (no CONFIG arg) runs the SDLC against `/home/exedev/sssf_config.yaml`; `just sbx run cmd test-pi-mirror "grep -c 'model:' /home/exedev/sssf_config.yaml"` shows the pre-filled models.
5. **Teardown:** `just sbx lifecycle teardown test-pi-mirror` completes (OpenRouter revoke path untouched).

## Risks / notes for the builder

- The `anthropic-messages` api flavor (kimi-coding, minimax-cn) is NOT covered by the old template — only `openai-completions` was proven. If pi rejects a provider block, gate C will name the model; the fix belongs in `pi_mirror.py` (field shape), not in the gate.
- If pi's models.json schema rejects unknown provider-level fields, mirror the template's field set exactly and nothing more.
- `models-store.json` is pi's cache; if pi ever stops writing it, `pi_mirror.py` fails loudly at FILL — that is the intended failure mode, not a silent fallback.
- Two of anything in one shared just scope collide: `fill.just`/`execute.just`/`setup.just` are IMPORTS of the root — no new `set` lines, no new top-level `name :=` variables.
