# Plan: drop the host-pi mirror — sandbox gets latest pi + built-in providers keyed by env vars

## Goal

Stop mirroring the host's pi agent state into sandboxes. `pi_mirror.py` goes away
entirely. Instead:

1. **Latest pi agent is provisioned on the VM** — `provision.sh` installs/upgrades
   `@earendil-works/pi-coding-agent` to the npm `latest` tag.
2. **The providers named in `sssf.config.yaml` are properly set up** — they are all
   pi *built-in* providers; no custom `models.json` registry is needed at all.
3. **API keys are provisioned** — the `.env` allowlist path (added by
   `specs/dee0bf80_sandbox-env-llm-keys.md`) flips from optional second path to
   **the** credential path: FILL ships the roster's keys into `app/.env` on the VM
   and fails fast if a roster provider's key is missing on the host.

## Verified facts that drive the design (recon evidence, pi 1.0.0 on host)

- **Every provider the rosters use is a pi built-in.** A fresh-HOME probe
  (`HOME=/tmp/pitest pi --list-models`, no `~/.pi/agent` at all) lists `deepseek`,
  `kimi-coding`, `minimax`, `zai`; with `MINIMAX_CN_API_KEY`/`ZAI_CODING_CN_API_KEY`/
  `OPENROUTER_API_KEY` set it also lists `minimax-cn`, `zai-coding-cn`, and the full
  `openrouter/*` catalog. The default roster (`adws/adw_sssf_config/sssf.config.yaml`)
  uses exactly `deepseek`, `kimi-coding`, `zai`, `minimax-cn` — all built-in.
- **`pi --list-models` only lists providers that have a credential available**
  (env var or stored auth). With `env -i` it lists nothing. So any remote gate or
  `run agent` invocation MUST source `app/.env` first — there is no `models.json`
  or `auth.json` on the VM to carry credentials anymore.
- **The authoritative provider → env-var map lives in pi itself:**
  `node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/env-api-keys.js`,
  function `getApiKeyEnvVars`. Roster-relevant rows:
  `deepseek→DEEPSEEK_API_KEY`, `zai→ZAI_API_KEY`, `zai-coding-cn→ZAI_CODING_CN_API_KEY`,
  `kimi-coding→KIMI_API_KEY`, `minimax→MINIMAX_API_KEY`, `minimax-cn→MINIMAX_CN_API_KEY`,
  `openrouter→OPENROUTER_API_KEY`, `openai→OPENAI_API_KEY`, `anthropic→ANTHROPIC_API_KEY`,
  `google→GEMINI_API_KEY`, `mistral→MISTRAL_API_KEY`, `xai→XAI_API_KEY`,
  `moonshotai→MOONSHOT_API_KEY`, `groq→GROQ_API_KEY`, `cerebras→CEREBRAS_API_KEY`,
  `fireworks→FIREWORKS_API_KEY`, `together→TOGETHER_API_KEY`, `baseten→BASETEN_API_KEY`.
- **Built-in models carry cost data** (`pi-ai/dist/providers/data/<provider>.json`
  has full `cost` blocks, e.g. `minimax-cn/MiniMax-M3` input 0.3 / output 1.2), so
  pi reports real per-call cost with NO `models.json`. The gate-D jq rate-table
  checks against `models.json` become obsolete; the live-cost half stays.
- **`adws/adw_modules/agent_pi.py:context_window()` reads
  `~/.pi/agent/models.json` UNGUARDED** (`json.loads(Path(MODELS_JSON).read_text())`)
  and is called for every agent session (`agents.py:202`). On a mirror-less sandbox
  that file no longer exists → every run would crash. This is the one **code** fix.
- **Consumers of `app/.env` inside the sandbox are already wired:** `just/adws.just`
  has `set dotenv-load` (working-directory = repo root = `app/`), and
  `adws/adw_modules/utils.py` does `load_dotenv()` + `operator_env()` copies
  `os.environ` into every agent subprocess. So `just adw sdlc` (the execute lane)
  picks up the shipped keys with NO change.
- **The host `.env` currently lacks `MINIMAX_CN_API_KEY`** (it has
  `DEEPSEEK_API_KEY`, `KIMI_API_KEY`, `MINIMAX_API_KEY`, `ZAI_API_KEY`). The default
  roster's documenter uses `minimax-cn/MiniMax-M3`. New FILL must FAIL FAST naming
  `MINIMAX_CN_API_KEY` until the operator adds it. **Do NOT edit the roster** —
  `adws/adw_sssf_config/` is a `protected_files` path; swapping `minimax-cn` →
  `minimax` is the operator's call, not this change's.

## Changes, file by file

### 1. DELETE `sandbox_mount/host/pi_mirror.py`

Nothing else remains that reads host pi state. (`TREE.md:72` documents it — see
change 9.)

### 2. `just/sandbox/lifecycle/fill.just` — the core rework

- **Header:** rewrite the "TWO shapes of secret cross the wire" paragraph. There is
  now ONE shape: the allowlisted LLM key vars from the host `.env`, shipped as
  environment variables into `app/.env` (0600, stdin only, never echoed). No host
  pi state (`~/.pi/agent/*`) is read at all; pi's built-in provider catalog carries
  baseUrl/api/cost.
- **Delete** the entire "ship the host pi model set + a per-sandbox config" block
  (the `MIRROR=…`, the three `uv run "$MIRROR" … | ssh …` pipes, the
  `MI_STAT`/`SE_STAT` proof lines). Replace it with a new block, placed where the
  mirror block was (after the clone gate, before the `.env` block):

  **a. Roster provider key check (fail fast).**
  ```bash
  ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"
  [ -f "$ROSTER" ] || { echo "fill: roster $ROSTER not found" >&2; exit 1; }
  PROVIDERS=$(awk '/^[[:space:]]*model:[[:space:]]/ {print $2}' "$ROSTER" \
              | sed 's|/.*||' | sort -u)
  [ -n "$PROVIDERS" ] || { echo "fill: parsed zero providers out of $ROSTER" >&2; exit 1; }

  # Provider -> env var, copied from pi's own getApiKeyEnvVars
  # (pi-ai/dist/env-api-keys.js). Keep in sync with setup.just gate E and
  # manage/mod.just doctor — three copies, one source of truth upstream in pi.
  key_var_for() {
    case "$1" in
      deepseek)      echo DEEPSEEK_API_KEY ;;
      zai)           echo ZAI_API_KEY ;;
      zai-coding-cn) echo ZAI_CODING_CN_API_KEY ;;
      kimi-coding)   echo KIMI_API_KEY ;;
      minimax)       echo MINIMAX_API_KEY ;;
      minimax-cn)    echo MINIMAX_CN_API_KEY ;;
      openrouter)    echo OPENROUTER_API_KEY ;;
      openai)        echo OPENAI_API_KEY ;;
      anthropic)     echo ANTHROPIC_API_KEY ;;
      google)        echo GEMINI_API_KEY ;;
      mistral)       echo MISTRAL_API_KEY ;;
      xai)           echo XAI_API_KEY ;;
      moonshotai)    echo MOONSHOT_API_KEY ;;
      groq)          echo GROQ_API_KEY ;;
      cerebras)      echo CEREBRAS_API_KEY ;;
      fireworks)     echo FIREWORKS_API_KEY ;;
      together)      echo TOGETHER_API_KEY ;;
      baseten)       echo BASETEN_API_KEY ;;
      *) return 1 ;;
    esac
  }

  MISSING=()
  for p in $PROVIDERS; do
      var=$(key_var_for "$p") \
        || { echo "fill: provider '$p' is not a known pi built-in — add its env" >&2
             echo "     mapping to fill.just/setup.just/manage or register it" >&2
             echo "     out of band" >&2; exit 1; }
      [ -n "${!var:-}" ] || MISSING+=("$var (provider $p)")
  done
  if [ "${#MISSING[@]}" -gt 0 ]; then
      echo "fill: roster providers need keys that are not set in the host environment:" >&2
      printf '      %s\n' "${MISSING[@]}" >&2
      echo "      add them to .env (see .env.sample) and re-run fill" >&2
      exit 1
  fi
  ```
  (`dotenv-load` on the lifecycle module already puts `.env` vars in the recipe
  environment; the recipe runs under `#!/usr/bin/env bash`, so `${!var}` is fine.)

  **b. Ship the roster verbatim** (no model rewriting, no host-catalog validation —
  the setup gate validates against the sandbox's own pi):
  ```bash
  cat "$ROSTER" | ssh "$HOST" 'cat > /home/exedev/sssf_config.yaml && chmod 644 /home/exedev/sssf_config.yaml'
  ```
  Fixed ABSOLUTE path, never `$HOME` (the two-quoting-hop problem documented in the
  current file — keep that comment).

  **c. Ship a derived `settings.json`** so bare `pi -p` (the `run agent` lane) lands
  on the roster's default. Parse `defaults.model` and `defaults.thinking` with the
  awk pattern setup.just gate D already uses:
  ```bash
  DEFAULT_MODEL=$(awk '
    /^defaults:[[:space:]]*$/ { d=1; next }
    /^[^[:space:]]/          { d=0 }
    d && /^[[:space:]]+model:[[:space:]]/ { print $2; exit }
  ' "$ROSTER")
  DEFAULT_THINKING=$(awk '
    /^defaults:[[:space:]]*$/ { d=1; next }
    /^[^[:space:]]/          { d=0 }
    d && /^[[:space:]]+thinking:[[:space:]]/ { print $2; exit }
  ' "$ROSTER")
  DP="${DEFAULT_MODEL%%/*}"; DM="${DEFAULT_MODEL#*/}"
  printf '{\n  "defaultProvider": "%s",\n  "defaultModel": "%s",\n  "defaultThinkingLevel": "%s"\n}\n' \
      "$DP" "$DM" "${DEFAULT_THINKING:-medium}" \
    | ssh "$HOST" 'mkdir -p "$HOME/.pi/agent" && umask 077 && cat > "$HOME/.pi/agent/settings.json" && chmod 600 "$HOME/.pi/agent/settings.json"'
  ```

  **d. Remove stale mirror artifacts** so a re-fill of a VM that once got the old
  mirror converges (an old `models.json` would shadow pi's built-in catalog with
  stale keys):
  ```bash
  ssh "$HOST" 'rm -f "$HOME/.pi/agent/models.json" "$HOME/.pi/agent/models-store.json"'
  ```
  Note in a comment: `auth.json` is left alone if present (pi tolerates it; nothing
  we ship writes it).

  **e. Proof lines** for the three shipped files via remote `stat -c "%a %s"`
  (same pattern as today; the config echo line loses the "every agent's model
  pre-filled" wording — models are NOT rewritten anymore, say "shipped verbatim").

- **Keep the `.env` allowlist block** (it becomes the credential path), with two edits:
  - Extend `LLM_KEY_VARS` with the pi built-in names not already there:
    `ZAI_CODING_CN_API_KEY`, `MINIMAX_CN_API_KEY`, `GROQ_API_KEY`,
    `CEREBRAS_API_KEY`, `FIREWORKS_API_KEY`, `TOGETHER_API_KEY`, `BASETEN_API_KEY`.
    (The roster key check above runs first, so for a valid roster `app/.env` always
    gets written; keep the no-keys skip line for robustness anyway.)
  - Update its comment: this is now THE credential path for the sandbox pi (pi's
    built-in providers read these env vars); not a secondary path.

### 3. `sandbox_mount/guest/provision.sh` — install the LATEST pi

- **Replace step 4 ("pi models.json")** with **"pi agent (latest)"**:
  ```bash
  step "4/9 pi agent (latest)"
  # No models.json, no mirrored registry: every roster provider is a pi BUILT-IN,
  # keyed by the env vars FILL ships into app/.env. What the sandbox needs from
  # this step is the binary itself, current — the exeuntu image may bake an old one.
  command -v npm >/dev/null 2>&1 || { echo "[provision] npm missing — the exeuntu image must ship node/npm" >&2; exit 1; }
  PI_PKG="@earendil-works/pi-coding-agent"
  CUR="$(pi --version 2>/dev/null || echo none)"
  LATEST="$(npm view "$PI_PKG" version)"
  if [[ "$CUR" == "$LATEST" ]]; then
    say "pi already at latest ($CUR)"
  else
    say "pi $CUR -> $LATEST"
    npm install -g "$PI_PKG@latest" || sudo npm install -g "$PI_PKG@latest"
  fi
  command -v pi >/dev/null 2>&1 || { echo "[provision] pi not on PATH after install" >&2; exit 1; }
  say "pi $(pi --version)"
  ```
  Builder notes:
  - Verify on the live VM whether global npm needs `sudo` (fleet-restore.sh used
    `--root`; provision.sh already uses sudo for /usr/local/bin symlinks). The
    `|| sudo …` fallback covers both; tighten it if the first attempt's failure
    mode turns out to be something other than permissions.
  - If pi installs to a prefix future non-interactive ssh shells don't see, add the
    same `/usr/local/bin` symlink trick step 2 uses for bun. Verify with a fresh
    `ssh $VM 'command -v pi'` (the setup gate's assertion B is exactly this).
- Keep the rest of the steps; the summary's `pi --version` / `pi --list-models`
  lines stay (the list-models line may now print 0 when keys aren't in the
  provision shell's env — reword that say-line to note keys live in app/.env, or
  source `app/.env` for the summary only. Builder's choice; do NOT fail on it.)

### 4. `just/sandbox/lifecycle/setup.just` — the gate follows the env-key reality

Keep provision → sentinel → gate. Header: the gate's credential story is now
"keys FILL shipped into `app/.env`, sourced before every pi call" — `ssh host cmd`
carries NO environment, so sourcing is the whole game.

- **Assertion B:** source the env file first inside REMOTE_B:
  ```bash
  set -a; [ -f "$HOME/app/.env" ] && . "$HOME/app/.env"; set +a
  ```
  then the existing `command -v pi` + non-empty + reject-"No models available"
  checks run unchanged. (With keys sourced, `pi --list-models` lists the built-in
  providers; without, it lists NOTHING — this is exactly why the source line is
  first.)
- **REMOTE_CDE:** same source line at the top (after `cd "$HOME/app"` it's
  `set -a; [ -f .env ] && . ./.env; set +a`).
  - **C (roster ping):** unchanged — the awk parse, the per-model
    `timeout 180 pi -p --no-tools --provider … --model …` ping, pass/FAIL lines,
    exit 2. Now it exercises env credentials + built-in catalog. Keep the comment
    but drop "host-mirrored" wording.
  - **D (non-zero cost):** KEEP only the live-call half (pi reports cost > 0).
    **DELETE both jq halves** (the all-four-cost-keys shape check and the per-model
    input-rate check) — they read `models.json`, which no longer exists; pi's
    built-in catalog carries the rates (verified in pi-ai's bundled data). Update
    the exit-3 summary wording.
  - **E (credential coverage):** rewrite as env-var presence. For each provider in
    `$PROVIDERS` (same derivation), map it through the same `key_var_for` case
    table (third copy — comment must say so) and assert the mapped var is non-empty
    in the sourced environment; unknown provider or empty var → FAIL line, exit 4.
- `gate_fail` help text: replace `pi --list-models` debug hint with
  `ssh … 'cd app && set -a && . ./.env && set +a && pi --list-models'`.

### 5. `just/sandbox/run/mod.just` — the `agent` lane sources the env file

The remote one-liner becomes:
```bash
ssh "$VM".exe.xyz "cd app && if [ -f .env ]; then set -a; . ./.env; set +a; fi; pi -p --session-id $SID $Q"
```
Update the recipe comment: no host-mirrored model set — pi's built-in catalog,
keyed by `app/.env`. The file header's "no SendEnv, nothing leaks" note stays
accurate (keys cross as a 0600 file via FILL, never as forwarded env).

### 6. `adws/adw_modules/agent_pi.py` — the one code fix

In `context_window()`:
```python
registry_path = Path(MODELS_JSON)
registry = json.loads(registry_path.read_text()) if registry_path.is_file() else {"providers": {}}
```
(Or an equivalent early-skip to the `_pi_catalog()` fallback.) Add a one-line
comment: sandboxes no longer carry a models.json — built-in providers come from
pi's own catalog. The `MODELS_JSON` env override (`PI_MODELS_PATH`) keeps working.

### 7. `just/sandbox/manage/mod.just` — doctor checks keys, not the mirror

Replace the `chk "host pi catalog readable" 'uv run … pi_mirror.py models …'` line
with a roster-keys check (dotenv-load is already set on this module):
```bash
chk "roster provider keys set" 'bash -c '"'"'
  ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"
  for p in $(awk "/^[[:space:]]*model:[[:space:]]/ {print \$2}" "$ROSTER" | sed "s|/.*||" | sort -u); do
    var=$(case "$p" in deepseek) echo DEEPSEEK_API_KEY;; zai) echo ZAI_API_KEY;; zai-coding-cn) echo ZAI_CODING_CN_API_KEY;; kimi-coding) echo KIMI_API_KEY;; minimax) echo MINIMAX_API_KEY;; minimax-cn) echo MINIMAX_CN_API_KEY;; openrouter) echo OPENROUTER_API_KEY;; *) echo "";; esac)
    [ -n "$var" ] && [ -n "${!var:-}" ] || { echo "missing key for provider $p" >&2; exit 1; }
  done
'"'"''
```
(Builder: get the quoting right; if this one-liner fights the eval-quoting in
`chk`, hoist the check into a tiny `sandbox_mount/host/roster_keys.sh` that fill.just
and doctor both call — that also collapses the mapping to TWO copies instead of
three. Prefer that if the fill.just case-table can live there too; fill.just would
`source` or call it. Decide by what parses cleanly; the plan tolerates either.)

### 8. `.env.sample` — env keys are now THE credential path

- Rewrite the top comment: FILL ships these into every sandbox as `app/.env`
  (0600); pi's built-in providers read them; **the roster decides which are
  required** — FILL fails and names the missing ones. No pi registry mirror exists
  anymore.
- Add the new allowlist names (`MINIMAX_CN_API_KEY`, `ZAI_CODING_CN_API_KEY`,
  `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `FIREWORKS_API_KEY`, `TOGETHER_API_KEY`,
  `BASETEN_API_KEY`) to the commented block, keeping each commented out.
- Keep the safety wording (disposable but not private; rotate on suspicion).

### 9. Docs/comments sweep (sentence-level, keep the repo honest)

- `README.md` line ~64 (credential boundary): rewrite — the exe.dev account is
  still the only host-only credential; LLM provider keys declared in `.env` are
  shipped by FILL into each sandbox's `app/.env` (0600) and read by pi's built-in
  providers. Delete "the host pi agent's provider keys are mirrored". Also the
  image caption at ~line 160 ("the host pi provider registry is mirrored into each
  sandbox") — update the caption text.
- `README.md` tech table row for Claude Code + Pi ("preinstalled on the VM") →
  pi is installed/upgraded to latest by provision (Claude Code no longer ships in
  sandboxes at all — check what the row says and make it true; sentence-level).
- `.claude/commands/install.md`: line ~57 — the LLM key list is now the REQUIRED
  roster credential path (FILL fails without the roster's keys), and add the new
  var names. Leave the OpenRouter-provisioning-key lines alone ONLY if they are
  still true; if `create.just` no longer reads `OPENROUTER_PROVISIONING_KEY`
  (verified: it does not), fix those two lines too (58, 60, 80) as drive-by truth
  — the install doc must not demand a dead key.
- `TREE.md` line 72: remove the `host/pi_mirror.py` entry (the file is deleted).
- Header comments in `fill.just` / `setup.just` / `provision.sh` /
  `run/mod.just` / `manage/mod.just`: sweep "mirror", "host-mirrored",
  "host pi catalog" wording to the env-key story. `grep -rn -i "pi_mirror\|host-mirrored\|mirror the host" just/ sandbox_mount/ README.md .claude/commands/ TREE.md`
  must return nothing after the change (specs/ is history — never touch it).

## What deliberately does NOT change

- `adws/adw_sssf_config/*.yaml` — rosters are `protected_files`; the `minimax-cn`
  key gap is surfaced to the operator by fill's fail-fast, not papered over by a
  roster edit.
- `create.just`, `teardown.just`, `observe.just`, `harvest.just`, `execute.just`
  (its `just adw` lane picks up `app/.env` via dotenv-load for free),
  `agent_pi.py`'s streaming/resume machinery.
- `/home/exedev/sssf_config.yaml` stays the fixed absolute roster path and
  setup/execute keep defaulting to it.
- The secret discipline: stdin-only pipes, 0600, never echo a value.

## Verification

1. **Static parse:** `just --list`, `just --list sbx`, `just --list sbx::run`,
   `just --list sbx::lifecycle`, `just --list sbx::manage` all exit 0.
2. **Mirror gone:** the grep sweep above returns nothing outside `specs/` and
   `adws/adw_data/`; `git status` shows `sandbox_mount/host/pi_mirror.py` deleted.
3. **pi built-in proof (host, no VM):** `rm -rf /tmp/picheck && mkdir /tmp/picheck`
   then `HOME=/tmp/picheck DEEPSEEK_API_KEY=x KIMI_API_KEY=x ZAI_API_KEY=x
   MINIMAX_CN_API_KEY=x pi --list-models` lists all four default-roster providers;
   same command with `env -i` (PATH kept) lists none. Also
   `npm view @earendil-works/pi-coding-agent version` prints the latest tag.
4. **Key-check logic (host, no VM):** run fill.just's provider loop standalone in
   /tmp against `adws/adw_sssf_config/sssf.config.yaml` — with
   `MINIMAX_CN_API_KEY` unset it must fail naming exactly that var; with it set it
   must pass. Scratch output to /tmp only.
5. **`agent_pi.py` guard:** `PI_MODELS_PATH=/tmp/does-not-exist.json uv run python
   -c "from adws.adw_modules.agent_pi import context_window; print(context_window('deepseek','deepseek-flash'))"`
   (run from repo root with `adws` importable — mirror how `provision.sh` step 7
   inserts `adws` into `sys.path`) — must return an int (0 is fine) instead of
   raising FileNotFoundError.
6. **Live mount (only with a VM):** add `MINIMAX_CN_API_KEY` to the host `.env`
   first (operator supplies it — without it, verify step 4's fail-fast is the
   observed behavior and note it in the report). Then
   `just sbx mount <run-id>` → all five gate assertions pass; gate C pings
   deepseek/kimi-coding/zai/minimax-cn through the sandbox pi; gate D reports
   non-zero cost. `just sbx run cmd <run-id> 'stat -c "%a" .env && cut -d= -f1 .env'`
   shows 0600 and NAMES only. Then the two-turn resume:
   `just sbx run agent <run-id> "remember the number 42, reply STORED"` /
   `just sbx run agent <run-id> "what number?"` → 42. Then
   `just sbx lifecycle teardown <run-id>`.
7. If no live sandbox is available, say so in the report and stop after 1–5.

## Risks / notes for the builder

- **Sourcing is the single point of failure.** Every remote pi invocation (gate B,
  C/D/E, `run agent`) must source `app/.env` first — a fresh ssh shell carries no
  env. `just adw` needs nothing (dotenv-load).
- The provider→env mapping table now lives in up to three places (fill.just,
  setup.just, manage/mod.just). Comment each copy with its upstream source
  (`pi-ai/dist/env-api-keys.js`). If a future pi adds/renames a provider, the
  fail-fast at FILL is the intended tripwire.
- pi's `--list-models` gating on credentials means an EMPTY `app/.env` sandbox
  looks broken to gate B even though pi is fine — but FILL's fail-fast makes that
  state unreachable for a valid roster.
- `~/.pi/agent/settings.json` on the VM is now generated from the roster, not the
  host — if the roster's `defaults.thinking` is absent the generator writes
  `medium`; pi validates the level string, and the roster's enum matches pi's.
- Do not resurrect a `models.json` "for safety": with env-keyed built-ins it is
  dead weight and would shadow catalog updates that ride with the latest pi.
