# just/sandbox/setup.just — PHASE 3 of 6: SETUP.
#
# Imported by the root justfile (not a module), so it shares the root's scope
# and settings. No `set` lines here on purpose: duplicating `dotenv-load` or
# `positional-arguments` is a hard error at parse time.
#
# What this phase does: run provision.sh inside the sandbox, wait for its
# sentinel, then run the five-assertion health gate. Nothing here creates or
# destroys a VM. On failure it prints how to get into the box and exits
# non-zero, because a gate that auto-destroys throws away the evidence.
#
# The OpenRouter PROVISIONING key never appears in this file, and the gate no
# longer reads the RUNTIME key either: C/D/E exercise the sandbox's own pi and
# its mirrored registry, none of which needs OpenRouter. They still run INSIDE
# the sandbox so the gate proves the sandbox's own egress works, not the host's.

# CONFIG picks which roster the gate checks. It has to be an ARGUMENT: C used to
# read $SSSF_CONFIG out of the remote environment, but `ssh host 'cmd'` carries
# no environment at all, so that read always fell through to the default. On a
# fan-out where each arm runs a different roster, every arm was gated against
# models it would never call — the gate passed and told you nothing. When the
# argument is empty it defaults to the per-sandbox config FILL ships at
# /home/exedev/sssf_config.yaml, and a MISSING file fails the gate rather than
# silently gating against the repo default. Pass the same path here that you pass
# to `just sbx lifecycle execute`.

# phase 3: provision the sandbox, then gate it (never destroys the VM). CONFIG picks the roster the gate checks
setup RUN_ID CONFIG="":
    #!/usr/bin/env bash
    set -euo pipefail

    RR="sandbox_mount/host/run_record.py"
    VM=$("$RR" get {{RUN_ID}} vm_name)
    SHA=$("$RR" get {{RUN_ID}} commit_sha)

    # run_record prints an empty line for an unset field, so emptiness is the
    # real check — a missing vm_name means CREATE never finished.
    [ -n "$VM" ]  || { echo "[setup] run record {{RUN_ID}} has no vm_name — run: just sbx lifecycle create {{RUN_ID}}" >&2; exit 1; }
    [ -n "$SHA" ] || { echo "[setup] run record {{RUN_ID}} has no commit_sha — run: just sbx lifecycle fill {{RUN_ID}}" >&2; exit 1; }

    HOST="$VM.exe.xyz"
    # ConnectTimeout only: every *.exe.xyz shares one host key and the wildcard
    # known_hosts entry is already installed, so ssh is non-interactive already.
    SSH=(ssh -o ConnectTimeout=15 "$HOST")

    echo "[setup] run {{RUN_ID}}  vm ${VM}  sha ${SHA}"

    # Every failure below routes through here: report, hand over the debug
    # command, exit non-zero. NEVER destroy — teardown stays an explicit choice.
    gate_fail() {
      echo ""
      echo "[setup] FAILED: $*" >&2
      echo "[setup] the VM is still running on purpose — the evidence is on the box:" >&2
      echo "[setup]   ssh ${HOST}" >&2
      echo "[setup]   ssh ${HOST} 'cd app && git status --porcelain'" >&2
      echo "[setup]   ssh ${HOST} 'pi --list-models'" >&2
      echo "[setup] tear it down only when you are done: just sbx lifecycle teardown {{RUN_ID}}" >&2
      exit 1
    }

    # Which roster to gate. When the caller passes none, use the per-sandbox
    # config FILL ships at a fixed absolute path; a MISSING file is a hard failure,
    # never a silent fall back to the repo default (that drift is what this change
    # removes).
    CONFIG={{ quote(CONFIG) }}
    if [ -z "$CONFIG" ]; then
        CONFIG="/home/exedev/sssf_config.yaml"
    fi
    "${SSH[@]}" "test -f $(printf '%q' "$CONFIG")" < /dev/null \
      || gate_fail "roster $CONFIG is missing on ${HOST} — run: just sbx lifecycle fill {{RUN_ID}}"
    echo "[setup] roster: ${CONFIG}"

    # ── 1. provision ─────────────────────────────────────────────────────────
    # Clear the sentinel first: re-running setup on the same VM would otherwise
    # find the PREVIOUS run's sentinel and declare victory before provision ran.
    echo "[setup] 1/3 provisioning (streaming provision.sh output)"
    "${SSH[@]}" 'rm -f /tmp/PROVISION_READY' < /dev/null \
      || gate_fail "cannot reach ${HOST} over ssh"
    # < /dev/null so ssh does not swallow this script's stdin; output streams live.
    "${SSH[@]}" 'bash app/sandbox_mount/guest/provision.sh' < /dev/null \
      || gate_fail "provision.sh exited non-zero (its last '── step ──' line names the stage)"

    # ── 2. sentinel ──────────────────────────────────────────────────────────
    # provision.sh touches /tmp/PROVISION_READY as its literal last line, so on
    # this synchronous path the file is already there and the loop exits on the
    # first probe. The poll is bounded anyway: it is the only completion signal
    # that stays correct if provision is ever backgrounded, and an unbounded
    # wait on a dead box is a hang, not a failure.
    echo "[setup] 2/3 waiting for /tmp/PROVISION_READY (max 60s)"
    ready=0
    for _ in $(seq 1 30); do
      if "${SSH[@]}" 'test -f /tmp/PROVISION_READY' < /dev/null; then ready=1; break; fi
      sleep 2
    done
    [ "$ready" -eq 1 ] || gate_fail "sentinel /tmp/PROVISION_READY never appeared"
    echo "[setup]     sentinel present"

    # ── 3. the gate ──────────────────────────────────────────────────────────
    echo "[setup] 3/3 health gate (5 assertions)"

    # A — git integrity. Content, not existence: an unsynced golden-VM clone
    # produced 5,641 zero-byte files and reported success, and truncation shows
    # up as ' M path'. Expected-vs-actual SHA is compared by prefix so a short
    # commit_sha in the record still matches a full HEAD.
    #
    # The tree must be CLEAN. Nothing legitimately dirties it: the sandbox
    # clones the repo and provisions around it, so any porcelain line at all
    # means something wrote where it should not have.
    echo "[gate] A git integrity"
    if "${SSH[@]}" 'bash -s' "$SHA" <<'REMOTE_A'; then
    set -uo pipefail
    cd "$HOME/app" || { echo "   no ~/app on this VM — FILL never ran"; exit 1; }
    want="${1:-}"
    head="$(git rev-parse HEAD)" || { echo "   git rev-parse failed — .git is damaged"; exit 1; }
    echo "   HEAD     ${head}"
    echo "   expected ${want}"
    case "$head" in
      "$want"*) ;;
      *) echo "   HEAD does not match the recorded commit_sha"; exit 1 ;;
    esac

    porcelain="$(git status --porcelain)"
    if [ -n "$porcelain" ]; then
      echo "   unexpected working-tree changes (the tree must be clean):"
      printf '%s\n' "$porcelain" | sed 's/^/     /'
      exit 1
    fi
    echo "   working tree clean"
    REMOTE_A
      echo "[gate] A PASS  git integrity"
    else
      gate_fail "assertion A — git integrity"
    fi

    # B — pi has models. `pi --list-models` EXITS 0 while printing
    # "No models available", so never trust $?: assert on the output, and
    # reject that exact string, which is otherwise one non-empty line and would
    # sail through a naive non-empty check.
    echo "[gate] B pi --list-models is non-empty"
    if "${SSH[@]}" 'bash -s' <<'REMOTE_B'; then
    set -uo pipefail
    # `command -v` first: without it a missing pi prints one line of
    # "command not found" and a bare non-empty check calls that a pass.
    command -v pi >/dev/null 2>&1 || { echo "   pi is not on PATH"; exit 1; }
    out="$(pi --list-models 2>&1 || true)"
    n="$(printf '%s\n' "$out" | grep -c . || true)"
    if [ "${n:-0}" -eq 0 ]; then
      echo "   pi --list-models printed nothing"; exit 1
    fi
    if printf '%s' "$out" | grep -qi 'no models available'; then
      echo "   pi says: No models available — ~/.pi/agent/models.json did not load"; exit 1
    fi
    echo "   ${n} lines from pi --list-models"
    REMOTE_B
      echo "[gate] B PASS  pi model registry loaded"
    else
      gate_fail "assertion B — pi --list-models empty or 'No models available'"
    fi

    # C, D, E run as ONE script inside the sandbox. C pings each roster model
    # THROUGH the sandbox's own pi, D asks pi for a real cost, and E checks the
    # registry's credentials. The OpenRouter runtime key is NOT read here anymore:
    # the gate now exercises the sandbox's pi/egress directly. That key still backs
    # the template fallback path (provision.sh / fill.just), written 0600 there.
    echo "[gate] C roster ping   D non-zero cost   E credential coverage"
    if "${SSH[@]}" 'bash -s' {{ quote(CONFIG) }} <<'REMOTE_CDE'; then
    set -uo pipefail
    cd "$HOME/app" || { echo "   no ~/app on this VM"; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "   jq missing (it ships in the exeuntu image)"; exit 1; }
    command -v pi >/dev/null 2>&1 || { echo "   pi is not on PATH"; exit 1; }

    # $1 is the CONFIG argument, forwarded over ssh as a positional because the
    # remote shell inherits no environment. The caller may leave it empty.
    CFG="${1:-}"
    [ -n "$CFG" ] || CFG="/home/exedev/sssf_config.yaml"
    [ -f "$CFG" ] || { echo "   missing ${CFG} — run FILL first"; exit 1; }

    # Every `model:` line is `provider/id`, and the provider half is a pi PROVIDER
    # name (deepseek, zai, kimi-coding, minimax-cn, zai-coding-cn). No stripping:
    # unlike the old `openrouter/<vendor>/<model>` form, both halves are exactly
    # what pi --provider/--model want.
    MODELS="$(awk '/^[[:space:]]*model:[[:space:]]/ {print $2}' "$CFG" | sort -u)"
    [ -n "$MODELS" ] || { echo "   parsed zero models out of ${CFG}"; exit 1; }

    # ── C: ping every model in the ACTIVE roster, THROUGH PI ─────────────────
    # pi resolves the provider block, reads its apiKey, picks the api flavor
    # (openai-completions AND anthropic-messages both appear in the host catalog),
    # and hits the baseUrl — so ONE call verifies credential + baseUrl + api
    # flavor + registry entry, which an OpenRouter curl never could for a direct
    # provider.
    ping_fail=0
    for m in $MODELS; do
      provider="${m%%/*}"; model="${m#*/}"
      resp="$(timeout 180 pi -p --no-tools --provider "$provider" --model "$model" \
                'ping - respond with pong' 2>/dev/null || true)"
      if [ -n "$(printf '%s' "$resp" | tr -d '[:space:]')" ]; then
        echo "   pass  ${m}"
      else
        echo "   FAIL  ${m}: pi returned no output (credential, baseUrl, api flavor, or registry entry)"
        ping_fail=1
      fi
    done

    # ── D: pi actually REPORTS cost ──────────────────────────────────────────
    # The thing being guarded is precise: adw_modules/agent_pi.py reads
    # usage.cost.total straight out of pi, and pi defaults every rate to ZERO
    # when models.json carries no `cost` block. A factory in that state runs
    # fine and reports $0.0000 forever while genuinely spending. Observed: a
    # 463.6k-token run logged $0.0000.
    #
    # Ask pi directly rather than asking OpenRouter (a key-usage diff rounds to $0
    # on a one-sentence call and would false-fail). The live call runs on the
    # roster's defaults.model — the model every agent inherits at minimum.
    DEFAULT_MODEL="$(awk '
      /^defaults:[[:space:]]*$/ { d=1; next }
      /^[^[:space:]]/          { d=0 }
      d && /^[[:space:]]+model:[[:space:]]/ { print $2; exit }
    ' "$CFG")"
    [ -n "$DEFAULT_MODEL" ] || DEFAULT_MODEL="$(printf '%s\n' "$MODELS" | head -n 1)"
    d_provider="${DEFAULT_MODEL%%/*}"; d_model="${DEFAULT_MODEL#*/}"
    cost_fail=0
    # jq, not python: an unindented line inside a recipe body TERMINATES the
    # recipe, and multi-line python cannot survive that. jq ships in the image.
    pi_cost="$(timeout 180 pi -p --mode json \
                 --provider "$d_provider" --model "$d_model" \
                 'Write one sentence about sandboxes.' 2>/dev/null \
               | jq -s '[.. | objects | select(has("cost")) | .cost.total // 0] | max // 0' \
               || echo 0)"
    if awk -v c="$pi_cost" 'BEGIN { exit !(c > 0) }'; then
      echo "   pi reports cost \$${pi_cost} on a live call (rate table is loaded)"
    else
      echo "   FAIL  pi reported cost 0 — models.json has no rate table, so every"
      echo "         run will log \$0.0000 while really spending money"
      cost_fail=1
    fi
    # Second half: the registry itself. pi's schema requires ALL FOUR of
    # input/output/cacheRead/cacheWrite together — a partial block fails
    # validation and pi drops THE ENTIRE ROSTER, not just that model. The host
    # catalog legitimately carries a few zero-rate models, so this asserts the
    # SHAPE (all four keys on every model) and that the models the roster will
    # actually call carry a non-zero input rate.
    MJ="$HOME/.pi/agent/models.json"
    if [ -f "$MJ" ] && jq -e '[.providers[].models[].cost
          | has("input") and has("output") and has("cacheRead") and has("cacheWrite")] | all' \
        "$MJ" >/dev/null 2>&1; then
      echo "   rate table present: every model in models.json carries all four cost keys"
    else
      echo "   FAIL  models.json has a partial rate block — pi drops the whole roster"
      cost_fail=1
    fi
    for m in $MODELS; do
      provider="${m%%/*}"; model="${m#*/}"
      rate="$(jq -r --arg p "$provider" --arg id "$model" \
        '[.providers[$p].models[] | select(.id == $id) | (.cost.input // 0)] | first // 0' \
        "$MJ" 2>/dev/null || echo 0)"
      if awk -v r="$rate" 'BEGIN { exit !(r > 0) }'; then
        :
      else
        echo "   FAIL  ${m} has a zero input rate in models.json — its runs log \$0.0000"
        cost_fail=1
      fi
    done

    # ── E: every roster provider has a credential ────────────────────────────
    # Spend no longer flows through the OpenRouter runtime key, so the old
    # limit-minus-usage reading said nothing. What matters now is that every
    # provider the roster calls carries a usable apiKey in the sandbox's registry
    # — a keyless (or still-`env:`) provider fails at call time.
    cred_fail=0
    PROVIDERS="$(printf '%s\n' "$MODELS" | sed 's|/.*||' | sort -u)"
    for p in $PROVIDERS; do
      key="$(jq -r --arg p "$p" '.providers[$p].apiKey // ""' "$MJ" 2>/dev/null || echo '')"
      case "$key" in
        ""|env:*) echo "   FAIL  provider ${p} has no usable apiKey in models.json"; cred_fail=1 ;;
        *)        echo "   credential present for ${p}" ;;
      esac
    done

    [ "$ping_fail" -eq 0 ] || exit 2
    [ "$cost_fail" -eq 0 ] || exit 3
    [ "$cred_fail" -eq 0 ] || exit 4
    REMOTE_CDE
      echo "[gate] C PASS  every roster model answered through pi"
      echo "[gate] D PASS  non-zero cost and a loaded rate table"
      echo "[gate] E PASS  every roster provider has a credential"
    else
      # Exit code tells which of the three failed; the per-line FAIL output above
      # already named the model or the reading.
      rc=$?
      case "$rc" in
        2) gate_fail "assertion C — at least one roster model did not answer through pi" ;;
        3) gate_fail "assertion D — pi reported no cost and/or models.json lacks rates" ;;
        4) gate_fail "assertion E — a roster provider has no credential in models.json" ;;
        *) gate_fail "assertions C/D/E — the remote gate script exited ${rc} (see output above)" ;;
      esac
    fi

    echo ""
    echo "[setup] GATE PASSED — {{RUN_ID}} is healthy on ${HOST}"
    echo "[setup] next: just sbx lifecycle observe {{RUN_ID}}"
