# Phase 2 — FILL. Put the code, the roster, and the sandbox's credentials inside
# the VM.
#
# Imported into the root justfile, so no `set` lines here and no local variables:
# six phase files share one scope and a `repo :=` in each would collide.
#
# ONE shape of secret crosses the wire here: the allowlisted LLM key vars the
# engineer set in the host .env, shipped as ENVIRONMENT VARIABLES into app/.env on
# the VM. There is no host pi state to mirror: every provider the rosters name is
# a pi BUILT-IN, keyed by those env vars, and pi's built-in catalog carries each
# provider's baseUrl/api/cost. The discipline is strict — stdin only, 0600, never
# echoed.

# clone the factory into the VM, optionally pin a sha, ship the roster + credentials: just sbx lifecycle fill <run-id> [sha]
fill RUN_ID *SHA:
    #!/usr/bin/env bash
    set -euo pipefail

    # Recipes already run from the root justfile's directory; cd makes that true
    # even if just is ever invoked with --justfile from elsewhere.
    cd "{{justfile_directory()}}"
    RR="sandbox_mount/host/run_record.py"

    # Public repo: no auth, no GitHub integration, no exe.dev git integration.
    # Source is the engineer's PUBLIC FORK (not upstream disler): it is the one
    # that carries the fix commits, so a fresh VM provisions itself with no
    # push access from the host.
    REPO="https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git"

    # *SHA is variadic: it interpolates to "" when unpinned, space-joined otherwise.
    # Only the first token is meaningful; extra words are a caller mistake we ignore.
    SHA_ARGS="{{SHA}}"
    PIN="${SHA_ARGS%% *}"

    VM=$("$RR" get {{RUN_ID}} vm_name)
    if [ -z "$VM" ]; then
        echo "fill: run record {{RUN_ID}} has no vm_name — run 'just sbx lifecycle create {{RUN_ID}}' first" >&2
        exit 1
    fi
    HOST="$VM.exe.xyz"   # all *.exe.xyz share one host key; the wildcard known_hosts entry is installed

    echo "==> fill: $VM — cloning app/ ${PIN:+(pin $PIN)}"

    # One remote script over stdin instead of a quoted one-liner: nothing here has
    # to survive two layers of shell quoting. Progress goes to stderr so stdout
    # carries exactly one machine-readable line: "<head_sha> <intended_sha>".
    # The OPTIONAL argument must be LAST. ssh does not pass argv — it joins the
    # args into one string that the remote login shell re-parses, so an empty "$PIN"
    # in the middle collapses to nothing and every argument after it shifts left.
    # MEASURED: with the pin second, an unpinned fill died on `$3: unbound variable`.
    CLONE_OUT=$(ssh "$HOST" bash -s -- "$REPO" "{{RUN_ID}}" "$PIN" <<'REMOTE'
    set -euo pipefail
    repo="$1"; run_id="$2"; pin="${3:-}"

    if [ -d app/.git ]; then
        # Idempotent re-run (also the golden-VM cp path, where app/ arrives stale).
        echo "app/ already present — fetching" >&2
        git -C app fetch --quiet --tags origin
        if [ -z "$pin" ]; then
            # ff-only: a sandbox that already ran an ADW carries commits that ARE
            # the run's output. Never reset over them; report and keep going.
            if ! { git -C app checkout --quiet main && git -C app merge --ff-only --quiet origin/main; }; then
                echo "WARN: could not fast-forward app/ to origin/main — keeping current HEAD" >&2
            fi
        fi
    else
        rm -rf app   # half-finished clone or a non-repo app/; the VM is disposable, the dir is not state
        git clone --quiet "$repo" app
    fi

    if [ -n "$pin" ]; then
        git -C app checkout --quiet "$pin"
    fi

    # The run branch. Created at whatever HEAD already is, so it adds no commit,
    # changes no file, and leaves the tree byte-identical — gate assertion A
    # compares HEAD's sha to the record and does not care what the branch is
    # called. Every commit the ADW makes now lands here instead of on main, which
    # is what lets HARVEST bundle exactly this run's work and nothing else.
    # Existing branch on a re-fill: switch to it, never re-create. Its commits ARE
    # the run's output.
    branch="sbx/$run_id"
    if git -C app rev-parse --verify --quiet "refs/heads/$branch" > /dev/null; then
        git -C app switch --quiet "$branch"
        echo "on existing run branch $branch" >&2
        # Switching back to the run branch UNDOES the `checkout $pin` above — the
        # branch still points where it did, so a re-fill onto a newer pin silently
        # kept the old code and only the gate noticed. Advance the branch itself,
        # ff-only so it can never move backwards over commits the run produced.
        # A pin that is not a descendant is a real conflict: say so, let the gate
        # fail, and leave the run's work alone.
        if [ -n "$pin" ] && ! git -C app merge --ff-only --quiet "$pin"; then
            echo "WARN: $branch cannot fast-forward to $pin — its commits are not on that line" >&2
        fi
    else
        git -C app switch --quiet -c "$branch"
        echo "run branch $branch created" >&2
    fi

    # Resolve the pin remotely rather than prefix-matching on the host: the pin may
    # be short, a tag or a branch, and only the clone can say what it means.
    intended=""
    if [ -n "$pin" ]; then
        intended=$(git -C app rev-parse --verify --quiet "$pin^{commit}" || true)
    fi
    printf '%s %s\n' "$(git -C app rev-parse HEAD)" "$intended"
    REMOTE
    )

    read -r HEAD_SHA INTENDED <<< "$CLONE_OUT"
    if [ -z "${HEAD_SHA:-}" ]; then
        echo "fill: clone produced no HEAD sha on $VM — VM left up for debugging" >&2
        exit 1
    fi

    # GATE FIRST, then record. A failed fill must leave commit_sha untouched: harvest
    # takes it as the baseline for `BASE..HEAD`, so writing the box's current HEAD here
    # would move that baseline PAST the run's own commits and harvest would then report
    # "the run committed nothing" while the commits sat on the branch, unbundled.
    if [ -n "$PIN" ]; then
        if [ -z "${INTENDED:-}" ]; then
            echo "fill: pin '$PIN' does not resolve to a commit in the clone — VM left up" >&2
            exit 1
        fi
        if [ "$HEAD_SHA" != "$INTENDED" ]; then
            echo "fill: GATE FAILED — HEAD $HEAD_SHA != intended $INTENDED — VM left up" >&2
            echo "      commit_sha left at $("$RR" get {{RUN_ID}} commit_sha) — harvest baseline intact" >&2
            exit 1
        fi
        echo "==> fill: gate ok — HEAD $HEAD_SHA matches pin $PIN"
    else
        echo "==> fill: no pin — HEAD $HEAD_SHA (recorded)"
    fi

    # commit_sha is what makes N runs comparable, so record the sha that is actually
    # checked out, never the one that was asked for.
    "$RR" set {{RUN_ID}} commit_sha="$HEAD_SHA"

    # ── ship the roster + a derived settings.json ────────────────────────────
    # No host pi state is mirrored any more: every provider the rosters name is a
    # pi BUILT-IN, keyed by an env var. The sandbox pi learns its model set from
    # the roster it is handed and its credentials from app/.env (shipped below);
    # pi's built-in catalog carries baseUrl/api/cost.
    #
    # The base roster is the ACTIVE one. The root justfile's `config` variable is
    # NOT visible here (this phase file is imported into the `sbx::lifecycle`
    # module, and modules inherit no variables), so read the same env var the
    # root's env_var_or_default reads, with the same fallback.
    ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"

    # FAIL FAST: every roster provider needs its key present in the host env
    # (dotenv-load already put .env vars there). roster_keys.sh owns the
    # provider -> env-var map; without this check a keyless provider would only
    # surface as a call-time failure inside the sandbox.
    sandbox_mount/host/roster_keys.sh "$ROSTER"

    # Ship the roster VERBATIM: no model rewriting, no host-catalog validation —
    # the setup gate validates against the sandbox's own pi. Fixed ABSOLUTE path,
    # never $HOME: execute/setup build remote command strings through two quoting
    # hops where $HOME expansion is fragile. observe.just already establishes the
    # exeuntu user is `exedev`. Holds no secrets -> 0644.
    cat "$ROSTER" | ssh "$HOST" 'cat > /home/exedev/sssf_config.yaml && chmod 644 /home/exedev/sssf_config.yaml'

    # A derived settings.json so a bare `pi -p` (the `run agent` lane) lands on
    # the roster's default provider/model/thinking. Parse the same `defaults`
    # block setup gate D reads.
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

    # Remove stale mirror artifacts so a re-fill of a VM that once got the old
    # mirror converges: an old models.json would shadow pi's built-in catalog
    # with stale keys. auth.json is left alone if present (pi tolerates it;
    # nothing we ship writes it).
    ssh "$HOST" 'rm -f "$HOME/.pi/agent/models.json" "$HOME/.pi/agent/models-store.json"'

    # Prove each landed (mode/size) without printing any content. Single-quoted
    # remote paths so $HOME expands on the VM, not here.
    SE_STAT=$(ssh "$HOST" 'stat -c "%a %s" "$HOME/.pi/agent/settings.json"')
    CF_STAT=$(ssh "$HOST" 'stat -c "%a %s" /home/exedev/sssf_config.yaml')
    echo "==> fill: ~/.pi/agent/settings.json (mode/size: $SE_STAT)"
    echo "==> fill: /home/exedev/sssf_config.yaml (mode/size: $CF_STAT) — shipped verbatim"

    # ── ship .env-declared LLM API keys (THE credential path) ──────────────
    # Keys the engineer set in the host .env cross as ENVIRONMENT VARIABLES into
    # app/.env on the VM (0600, stdin only, never echoed). This is now THE
    # credential path for the sandbox pi: its built-in providers read these env
    # vars, and every remote pi invocation (setup gates, `run agent`, `just adw`
    # via dotenv-load) sources app/.env first. Also serves anything else that
    # reads keys from the environment (the ADW python, SDKs).
    # ALLOWLISTED on purpose: host-only overrides (PI_MODELS_PATH, SSSF_CONFIG,
    # ENGINEER_NAME, PI_PATH) must never leak into the box.
    LLM_KEY_VARS=(
        ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY
        GEMINI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY
        ZAI_CODING_CN_API_KEY MOONSHOT_API_KEY KIMI_API_KEY MINIMAX_API_KEY
        MINIMAX_CN_API_KEY MISTRAL_API_KEY XAI_API_KEY GROQ_API_KEY
        CEREBRAS_API_KEY FIREWORKS_API_KEY TOGETHER_API_KEY BASETEN_API_KEY
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
        echo "==> fill: no LLM key vars set in .env — skipping app/.env (nothing to ship)"
    fi
