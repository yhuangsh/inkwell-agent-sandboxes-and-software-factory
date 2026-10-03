# Plan: provision LLM API keys to sandboxes via environment variables in `.env`

## Goal

Let the engineer declare LLM API keys as environment variables in the host `.env`
file (e.g. `ANTHROPIC_API_KEY=`, `OPENAI_API_KEY=`) and have **FILL**
(`just sbx lifecycle fill`) ship them into the sandbox as environment variables,
landing in `app/.env` on the VM. Today the ONLY credential path is the pi
registry mirror (`pi_mirror.py` → `~/.pi/agent/models.json`); anything that reads
keys from the environment — Claude Code (`ANTHROPIC_API_KEY`), SDKs, the ADW
python (`adw_modules/utils.py` calls `load_dotenv()`), just recipes
(`just/adws.just` has `set dotenv-load`) — has nothing to read inside the box.

The pi mirror stays the primary credential path and is **not** modified. This
change adds a second, complementary path: `.env`-declared keys cross as
environment variables.

## Current state (verified by reading the code)

- `just/sandbox/lifecycle/mod.just` sets `dotenv-load`, so `fill.just` recipes
  already see every var defined in the host `.env` in their environment. No
  settings change is needed to *read* the keys.
- `just/sandbox/lifecycle/fill.just` ships three documents over ssh stdin pipes
  (models.json 0600, settings.json 0600, sssf_config.yaml 0644) and prints
  mode/size proof lines, never content. This is the pattern to reuse.
- The OLD OpenRouter mechanism (removed by `specs/3e5f26d0_sandbox-drop-openrouter.md`)
  used to write `OPENROUTER_API_KEY=...` into `app/.env` on the VM from FILL —
  so `app/.env` as the landing spot is a proven pattern in this codebase, and
  `.env` is gitignored (never committed, never cloned into the box by the git
  clone FILL performs).
- Consumers on the VM: `just adw` (`set dotenv-load`, working-directory = repo
  root = `app/`) and `adws/adw_modules/utils.py` (`load_dotenv()` +
  `operator_env()` copies `os.environ` into every agent subprocess). So a key in
  `app/.env` reaches every ADW agent process.
- `sandbox_mount/guest/provision.sh` does not touch `app/.env` and gate
  assertion A (clean working tree) ignores untracked-but-gitignored files —
  `git status --porcelain` does not list gitignored files, so writing
  `app/.env` will NOT trip gate A. (Verified: `.env` is in `.gitignore`.)

## Design decisions

1. **Fixed allowlist of well-known var names.** Only these vars are considered,
   and only when non-empty:
   `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
   `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY`,
   `MOONSHOT_API_KEY`, `KIMI_API_KEY`, `MINIMAX_API_KEY`, `MISTRAL_API_KEY`,
   `XAI_API_KEY`.
   An allowlist (not "ship all of `.env`") keeps host-only overrides like
   `PI_MODELS_PATH`, `SSSF_CONFIG`, `ENGINEER_NAME`, `PI_PATH` from leaking into
   the box, and keeps the secret surface explicit and auditable.
2. **Landing spot: `app/.env` on the VM, mode 0600**, written via an ssh stdin
   pipe (`printf … | ssh "$HOST" 'umask 077 && cat > "$HOME/app/.env"'`) —
   never argv, never a temp file, never echoed. Same discipline as the
   models.json block directly above it in `fill.just`.
3. **Non-fatal when nothing is set.** If no allowlisted var has a value, FILL
   prints a skip line and continues — the pi mirror alone remains a valid
   configuration, so existing mounts are unaffected.
4. **Proof line prints var NAMES only, never values** (plus mode/size stat),
   matching the existing `MI_STAT`/`SE_STAT`/`CF_STAT` pattern.
5. **Out of scope:** merging `.env` keys into the mirrored `models.json`
   (gate E in `setup.just` requires literal `apiKey` values and rejects `env:`
   references; touching `pi_mirror.py`/the registry schema is a separate,
   riskier change). Also out of scope: per-key spend caps / revocation — the old
   mint-and-reap apparatus stays deleted.

## Changes

### 1. `just/sandbox/lifecycle/fill.just` — ship the env keys

- Header comment: update the "ONE kind of secret crosses the wire" paragraph —
  there are now TWO shapes of secret crossing: the host pi provider registry
  (models.json) and the allowlisted `.env` key vars (app/.env). Both are
  stdin-only, 0600, never echoed.
- After the existing `CF_STAT` proof block at the end of the recipe, add:

```bash
    # ── ship .env-declared LLM API keys (optional) ─────────────────────────
    # Keys the engineer set in the host .env cross as ENVIRONMENT VARIABLES into
    # app/.env on the VM (0600, stdin only, never echoed). The pi registry
    # mirror above stays the primary credential path; these serve anything that
    # reads keys from the environment — `just adw` (dotenv-load), the ADW python
    # (utils.load_dotenv -> operator_env), Claude Code (ANTHROPIC_API_KEY), SDKs.
    # ALLOWLISTED on purpose: host-only overrides (PI_MODELS_PATH, SSSF_CONFIG,
    # ENGINEER_NAME, PI_PATH) must never leak into the box.
    LLM_KEY_VARS=(
        ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY
        GEMINI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY
        MOONSHOT_API_KEY KIMI_API_KEY MINIMAX_API_KEY MISTRAL_API_KEY
        XAI_API_KEY
    )
    ENV_CONTENT=""
    SHIPPED=()
    for v in "${LLM_KEY_VARS[@]}"; do
        val="${!v:-}"
        if [ -n "$val" ]; then
            ENV_CONTENT+="$v=$val"$'\n'
            SHIPPED+=("$v")
        fi
    done
    if [ "${#SHIPPED[@]}" -gt 0 ]; then
        printf '%s' "$ENV_CONTENT" \
            | ssh "$HOST" 'umask 077 && cat > "$HOME/app/.env" && chmod 600 "$HOME/app/.env"'
        ENV_STAT=$(ssh "$HOST" 'stat -c "%a %s" "$HOME/app/.env"')
        # NAMES only — a proof line that prints a value defeats the 0600.
        echo "==> fill: app/.env (mode/size: $ENV_STAT) — env keys: ${SHIPPED[*]}"
    else
        echo "==> fill: no LLM key vars set in .env — skipping app/.env (pi mirror is the credential path)"
    fi
```

  Notes for the builder:
  - This recipe runs under `#!/usr/bin/env bash`, so `${!v}` indirect expansion
    and arrays are fine.
  - `dotenv-load` on the lifecycle module puts the host `.env` vars into the
    recipe environment; unset/empty vars are skipped by the `[ -n "$val" ]` test.
  - The `fill` recipe re-runs idempotently: `cat >` overwrites any previous
    `app/.env`, so a re-fill after editing `.env` converges the box.
  - Key values must be single-line (dotenv format); say so in `.env.sample`.

### 2. `.env.sample` — document the new section

- Replace the top comment block ("Inference credentials are NOT kept here…") so
  it no longer claims env-provided keys are impossible. New text: the pi
  registry mirror remains the primary path; the vars below are an OPTIONAL
  second path for tools that read keys from the environment.
- Add a new commented section between the header and "Optional overrides":

```
# ─────────────────────────────────────────────────────────────────────────────
# LLM API keys (optional) — provisioned INTO every sandbox by FILL
# ─────────────────────────────────────────────────────────────────────────────
#
# Any of these you set here are copied to app/.env (0600) on each sandbox by
# `just sbx lifecycle fill`. Only the names on this allowlist ever cross;
# single-line values only. Remember: a sandbox is disposable but not private —
# prefer per-provider keys you are comfortable seeing on a throwaway VM, and
# rotate any key you suspect leaked. The pi registry mirror (host
# ~/.pi/agent) stays the primary credential path and needs nothing here.
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# OPENROUTER_API_KEY=
# GEMINI_API_KEY=
# GOOGLE_API_KEY=
# DEEPSEEK_API_KEY=
# ZAI_API_KEY=
# MOONSHOT_API_KEY=
# KIMI_API_KEY=
# MINIMAX_API_KEY=
# MISTRAL_API_KEY=
# XAI_API_KEY=
```

### 3. `README.md` — one-paragraph touch-up

- In **Install → Manual Install**, the `.env` step currently reads "optional
  overrides only; inference creds live in the host pi registry". Update to:
  optional overrides plus optional LLM API keys that FILL provisions into each
  sandbox as `app/.env` (see `.env.sample`).
- In the credential-boundary paragraph ("One credential is the entire reason…"),
  add one sentence: besides the mirrored pi registry, keys declared in `.env`
  are also carried into each sandbox by FILL, written 0600 to `app/.env`.
- Do NOT restructure the README; two sentence-level edits only.

### 4. `.claude/commands/install.md` — one-line touch-up (optional but cheap)

- Where it says to tell the user which keys to fill in `.env` (around line 57),
  mention the optional LLM key allowlist so a fresh install knows the env path
  exists.

## Files touched

| File | Change |
|---|---|
| `just/sandbox/lifecycle/fill.just` | new env-key shipping block + header comment |
| `.env.sample` | new documented allowlist section; header comment corrected |
| `README.md` | two sentence-level updates (install step, credential boundary) |
| `.claude/commands/install.md` | one-line mention of the optional key vars |

**Files that need no change:** `sandbox_mount/host/pi_mirror.py` (registry path
untouched), `sandbox_mount/guest/provision.sh` (`app/.env` is gitignored, gate A
stays green), `just/sandbox/lifecycle/setup.just` (gates B–E only read the pi
registry; no new assertion needed for an optional path),
`just/sandbox/lifecycle/create.just` / `teardown.just` (nothing minted, nothing
to revoke), `just/sandbox/manage/*` (doctor's checks unchanged — the env path is
optional, so doctor must not require it).

## Verification

1. **Parse check:** `just --list sbx::lifecycle` and `just --list sbx` exit 0
   (just parses every imported file — a syntax slip in fill.just fails here).
2. **Local logic check (no VM):** in `/tmp`, source a dummy env and run just the
   allowlist loop:
   `ANTHROPIC_API_KEY=sk-test-1 OPENAI_API_KEY= ZAI_API_KEY=zai-test bash -c '<the loop, printing SHIPPED and ENV_CONTENT to /tmp>'`
   — expect `SHIPPED=(ANTHROPIC_API_KEY ZAI_API_KEY)`, empty values skipped,
   host-only vars like `PI_MODELS_PATH` never picked up. Nothing written to the
   repo.
3. **`.env.sample` sanity:** `cp .env.sample /tmp/env.test && grep -c 'API_KEY' /tmp/env.test`
   shows the allowlist entries; confirm no uncommented key lines.
4. **Live check (only if an exe.dev sandbox is available):**
   - Set one real key (e.g. `DEEPSEEK_API_KEY`) in the host `.env`.
   - `just sbx lifecycle fill <run-id>` → expect the new proof line
     `==> fill: app/.env (mode/size: 600 …) — env keys: DEEPSEEK_API_KEY`.
   - `just sbx run cmd <run-id> 'stat -c "%a" .env && cut -d= -f1 .env'` →
     mode `600`, names only (never `cat` the file).
   - `just sbx lifecycle setup <run-id>` → the 5-assertion gate still passes
     (proves gate A tolerates the gitignored `app/.env`).
   - With NO keys set in `.env`, re-fill → expect the skip line and a passing
     fill (backwards compatibility).
5. If no live sandbox is available, state that explicitly in the builder report
   and stop after checks 1–3.
