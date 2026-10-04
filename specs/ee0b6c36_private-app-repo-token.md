# Plan: PRIVATE app-repo support via APP_REPO_GIT_TOKEN

## Goal

A sandbox may mount a PRIVATE app repo. A git personal access token comes from the
host `.env` as a new allowlisted variable `APP_REPO_GIT_TOKEN` and rides the
factory's ONE existing credential path: shipped by FILL stdin-only into
`app/.env` on the VM (0600, never echoed, never logged, never in the trace db,
never in any committed file). The token authenticates the target clone/fetch on
the VM via an ephemeral `GIT_ASKPASS` helper, so the stored `origin` URL never
contains it.

## Hard invariants (from the request — every one gets an explicit check)

1. Public repos keep working with NO token — hello-server and inkwell flows unchanged.
2. A private repo with no token fails with a NAMED error telling the user to set
   `APP_REPO_GIT_TOKEN` in `.env`.
3. After clone, `git -C app/target remote get-url origin` on the VM must NOT
   contain the token (clean URL only).
4. The FACTORY repo clone stays public and credential-free (first remote script
   in fill.just is untouched).
5. The token VALUE never appears in any command output the builder runs —
   verify presence/shape (count, length, prefix class), never echo it.

## Current behavior (verified by reading the code)

- `just/sandbox/lifecycle/fill.just`, recipe `fill RUN_ID *SHA`:
  - Parses `app.repo` / `app.ref` / `app.path` from the active roster
    (`$SSSF_CONFIG`, default `adws/adw_sssf_config/sssf.config.yaml`) with awk.
  - TARGET mode clones the factory repo (REMOTE script, public, no auth) into
    `~/app`, then clones `app.repo` (REMOTE2 script, public, no auth — comment
    at the top says "Public repo: no auth") into `~/app/<path>` (default
    `target`), creates run branch `sbx/<run-id>`, and records `commit_sha`.
  - LAST block (~line 192, comment "ship .env-declared LLM API keys") iterates
    the `LLM_KEY_VARS` allowlist, ships set vars over ssh stdin into
    `$HOME/app/.env` (umask 077, chmod 600), echoes NAMES only.
  - `sandbox_mount/host/roster_keys.sh` fail-fast check sits just before the
    roster ship, after both clones.
- `justfile` / `just/sandbox/mod.just` both set `dotenv-load`; an explicitly
  exported env var (even empty) is NOT overridden by `.env` — this is the lever
  for the no-token negative test (`APP_REPO_GIT_TOKEN= just ...`).
- `just sbx mount <id>` = create → fill → setup → observe (mount.just). SETUP
  runs gates A–E (A git integrity incl. target HEAD == commit_sha, B pi current,
  C roster ping, D non-zero cost, E provider key coverage).
- Trace db lives on the VM at `$HOME/app/adws/adw_data/sssf.db` (teardown tars a
  copy home). Run records live host-side in `.sandbox/runs/<run-id>.json`
  (gitignored).
- `.env` already contains `APP_REPO_GIT_TOKEN` (verified by count only:
  `grep -c '^APP_REPO_GIT_TOKEN=' .env` → 1). Value never read.
- Test repo: `https://github.com/yhuangsh/hello-private` (hello-server content,
  main at 89b1ae1; hello-server main is 89b1ae17dbf7b0d48c9200cabc11333a26faf56d).

## Changes

### 1. `just/sandbox/lifecycle/fill.just` (the core change)

**a) Reorder: ship credentials BEFORE the target clone.**
Move the final `.env`-shipping block (the `LLM_KEY_VARS` loop through the
`env keys:` echo) — and the `roster_keys.sh "$ROSTER"` fail-fast check with it,
so "fails fast before it ships anything" stays true — to just AFTER the
factory-clone gate + `"$RR" set {{RUN_ID}} factory_sha=...` line and BEFORE the
`if [ "$MODE" = vendored ]` branch. At that point `~/app` (the factory clone)
exists, so writing `$HOME/app/.env` works on fresh and re-fill runs alike. The
roster ship / settings.json / stats blocks stay where they are. Update the
block's header comment: it is THE credential path, now carrying the LLM keys AND
the optional app-repo git token.

**b) Allowlist the token.**
Add `APP_REPO_GIT_TOKEN` to the shipped-vars array (renaming `LLM_KEY_VARS` to
e.g. `CRED_ENV_VARS` is encouraged; keep the names-only `env keys:` echo as the
proof line — `APP_REPO_GIT_TOKEN` appearing in that NAMES list is the intended
evidence of shipping). Also update the file-top comment ("ONE shape of secret
crosses the wire here: the allowlisted LLM key vars …") to mention the git token
riding the same path. Clarify the existing `REPO=` comment ("Public repo: no
auth") to say it is the FACTORY repo that stays public/credential-free.

**c) REMOTE2 (target clone) — token-aware auth, nothing persisted.**
At the top of the REMOTE2 script (after the positional reads):

```bash
# Token, if FILL shipped one, lives only in app/.env (0600). Never echoed:
# read it into a shell var; auth rides an ephemeral askpass so the stored
# origin URL stays the clean roster URL.
token=""
if [ -f "$HOME/app/.env" ]; then
    token=$(grep -m1 '^APP_REPO_GIT_TOKEN=' "$HOME/app/.env" | cut -d= -f2- || true)
fi
export GIT_TERMINAL_PROMPT=0   # private repo + no creds must FAIL, never hang
if [ -n "$token" ]; then
    ASKPASS=$(mktemp)
    chmod 700 "$ASKPASS"
    cat > "$ASKPASS" <<'ASKPASS_EOF'
#!/bin/sh
# git asks twice: username, then password. A GitHub PAT goes in as the
# password with any non-empty username; the token is read from app/.env at
# prompt time so it never sits in this file, in argv, or in the remote URL.
case "$1" in
    *sername*) echo "x-access-token" ;;
    *) grep -m1 '^APP_REPO_GIT_TOKEN=' "$HOME/app/.env" | cut -d= -f2- ;;
esac
ASKPASS_EOF
    trap 'rm -f "$ASKPASS"' EXIT   # ephemeral: gone on success AND on failure
    export GIT_ASKPASS="$ASKPASS"
fi
```

Then wrap BOTH network ops (the re-run `git -C "$dir" fetch` and the fresh
`git clone --quiet "$repo" "$dir"`) so a failure produces the NAMED errors
(`set -e` would otherwise abort silently). The clone URL stays the clean
`$repo` in all cases:

- On failure with token EMPTY:
  `fill: APP_REPO_PRIVATE_NO_TOKEN — target clone of <repo> failed; if this repo is private, set APP_REPO_GIT_TOKEN in the host .env and re-run: just sbx lifecycle fill <run-id>`
  then `exit 1`. (Print the repo URL, never the token.)
- On failure with token SET:
  `fill: APP_REPO_CLONE_FAILED — target clone of <repo> failed WITH APP_REPO_GIT_TOKEN set; check the token's existence, scope (repo read) and expiry — the token is never printed`
  then `exit 1`.

Because the host recipe runs `set -euo pipefail` and captures REMOTE2 in a
command substitution, ssh's non-zero exit aborts fill with the remote stderr
already shown — the named error reaches the user with no extra host plumbing.

**d) Post-clone non-persistence assertion (invariant 3), inside REMOTE2**
after the clone/fetch succeeds and only when `token` is non-empty:

```bash
url=$(git -C "$dir" remote get-url origin)
case "$url" in
    *"$token"*) echo "fill: APP_REPO_TOKEN_LEAK — token present in origin URL of $dir" >&2; exit 1 ;;
esac
```

On the leak branch print ONLY the named error — never `$url` (it would carry
the token) and never `$token`.

**e) Untouched:** the factory-clone REMOTE script, roster/settings shipping,
gate logic, run-record writes. No changes to `roster_keys.sh` (the token is not
a provider key).

### 2. `.env.sample`

New commented section after the LLM-keys block:

```
# ─────────────────────────────────────────────────────────────────────────────
# App repo access (optional — only for PRIVATE app repos)
# ─────────────────────────────────────────────────────────────────────────────
# A git personal access token with READ access to the app repo your roster's
# `app.repo` names. Only needed when that repo is private; public repos clone
# unauthenticated and this may stay unset. Rides the same path as the LLM keys:
# FILL ships it stdin-only into app/.env (0600) on each sandbox, the target
# clone authenticates through an ephemeral askpass, and the stored git remote
# URL never contains it. NEVER put this token in a roster — rosters are
# committed (644). A private repo without it fails FILL with a named error.
# APP_REPO_GIT_TOKEN=
```

### 3. `README.md`

- Setup section, `### 1. Set up a new app`: the paragraph currently opens "Make
  your app repo public, and put a `sssf.app.yaml` at its root …". Rework it:
  the manifest requirement stands; the repo may be public (zero config) OR
  private. Add a short private-repo paragraph: set `APP_REPO_GIT_TOKEN` (a PAT
  with read access) in `.env`; FILL ships it to `app/.env` (0600) on the VM
  through the same credential path as the LLM keys; the clone authenticates via
  an ephemeral askpass so the stored remote URL never carries the token; a
  private repo without the token fails FILL naming `APP_REPO_GIT_TOKEN`.
- The app-contract YAML example comment (`repo: https://github.com/<owner>/<app-repo>.git   # public, unauthenticated clone`, ~line 145): adjust to
  `# public, or private with APP_REPO_GIT_TOKEN in .env`.
- Optionally one clause in the credential-boundary paragraph (~line 64).
  Keep the README diff small; no other sections change.

## Token-handling rules for the builder (invariant 5)

- Never `cat .env`, never `echo $APP_REPO_GIT_TOKEN`, never interpolate the
  token into a command string whose text gets logged.
- Load it into a shell var when a comparison is needed:
  `TOKEN=$(grep -m1 '^APP_REPO_GIT_TOKEN=' .env | cut -d= -f2-)`
  then use `grep -c -F "$TOKEN" <file>` / `case "$x" in *"$TOKEN"*) …` — the
  command TEXT contains no value, and grep prints only counts.
- Shape check at most: `[ ${#TOKEN} -gt 20 ] && echo "token present (length ${#TOKEN})"`.
- All scratch output (mount logs, scratch roster) goes to `/tmp`, never the repo.

## Verification (fresh VMs, end-to-end)

### 0. Preflight (no value exposure)
```bash
grep -c '^APP_REPO_GIT_TOKEN=.' .env          # expect 1 (name present, non-empty)
TOKEN=$(grep -m1 '^APP_REPO_GIT_TOKEN=' .env | cut -d= -f2-)
[ ${#TOKEN} -gt 20 ] && echo "token present (length ${#TOKEN})"
just --list sbx                                # fill.just still parses
```

### 1. Private mount, green end-to-end
```bash
cp adws/adw_sssf_config/sssf.hello.config.yaml /tmp/sssf.hello-private.config.yaml
# edit /tmp copy ONLY: app.repo -> https://github.com/yhuangsh/hello-private.git
# (keep ref: main, path: target, manifest: sssf.app.yaml)
SSSF_CONFIG=/tmp/sssf.hello-private.config.yaml just sbx mount priv-check 2>&1 | tee /tmp/priv-mount.log
```
Assert from the log: fill ships `app/.env` with `APP_REPO_GIT_TOKEN` in the
names list; target clone of hello-private succeeds; setup gates A–E all PASS;
observe prints URLs. Get the run id (`sandbox_mount/host/run_record.py list`).
Then:
```bash
just sbx run cmd <id> 'git -C app/target remote get-url origin'   # == https://github.com/yhuangsh/hello-private.git, no token
just sbx run cmd <id> 'git -C app/target rev-parse HEAD'          # starts with 89b1ae1
just sbx run cmd <id> 'git -C app/target branch --show-current'   # sbx/<id>
just sbx run cmd <id> 'stat -c "%a" app/.env; grep -c "^APP_REPO_GIT_TOKEN=" app/.env'   # 600 and 1
just sbx run cmd <id> 'ls -a ~ | grep -ci askpass; true'          # 0 — helper is gone
```

### 2. Leak sweep (token only ever in `$TOKEN` / VM-local var, never literal)
```bash
grep -c -F "$TOKEN" /tmp/priv-mount.log        # 0 — mount logs clean
grep -c -F "$TOKEN" .sandbox/runs/<id>.json    # 0 — run record clean
just sbx run cmd <id> 'T=$(grep -m1 "^APP_REPO_GIT_TOKEN=" app/.env | cut -d= -f2-); c=0; for f in app/adws/adw_data/sssf.db*; do [ -f "$f" ] && c=$((c + $(grep -c -F "$T" "$f" || true))); done; echo "trace-db hits: $c"'   # 0
```

### 3. Named error on private repo with NO token (invariant 2)
```bash
SSSF_CONFIG=/tmp/sssf.hello-private.config.yaml just sbx lifecycle create priv-notoken
APP_REPO_GIT_TOKEN= SSSF_CONFIG=/tmp/sssf.hello-private.config.yaml just sbx lifecycle fill <new-id>
```
(dotenv-load does not override an explicitly-exported var; the fill output's
`env keys:` line must NOT list APP_REPO_GIT_TOKEN — that also proves the
override worked.) Expect: non-zero exit, message contains
`APP_REPO_PRIVATE_NO_TOKEN` and "set APP_REPO_GIT_TOKEN in the host .env";
VM left up. Then `just sbx lifecycle teardown <new-id>`.

### 4. Public regression (invariant 1)
```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount pub-check 2>&1 | tee /tmp/pub-mount.log
# gates A–E green, hello-server target cloned, remote URL clean.
# Strict no-token public check via idempotent re-fill on the SAME VM:
APP_REPO_GIT_TOKEN= SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx lifecycle fill <pub-id>
# succeeds; fetch path ran with no token; then:
grep -c -F "$TOKEN" /tmp/pub-mount.log          # 0
```
Inkwell smoke (fill path is what changed; setup gates are roster/pi-side):
```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml just sbx lifecycle create ink-check
SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml just sbx lifecycle fill <ink-id>
just sbx run cmd <ink-id> 'git -C app/target remote get-url origin'   # clean inkwell URL
```
(Full setup on the inkwell VM is optional; run it if time/cost allow.)

### 5. Cleanup and landing
- `just sbx lifecycle teardown <id>` for every VM created (priv, priv-notoken,
  pub, ink).
- `rm -f /tmp/sssf.hello-private.config.yaml /tmp/priv-mount.log /tmp/pub-mount.log`
  (scratch roster was in /tmp — never in the repo, never committed).
- `git status` clean after committing the change set; no token substring
  anywhere in the diff (`git diff --cached | grep -c -F "$TOKEN"` → 0).

## Out of scope

Factory-repo credentials (stays public), harvest (local bundle, no network),
the parked items (ref-guard, rollback-index, deleted_files). No changes to
setup.just / observe.just / provision.sh / roster_keys.sh.

## Files touched

- `just/sandbox/lifecycle/fill.just` — reorder .env ship before target clone,
  allowlist APP_REPO_GIT_TOKEN, token-aware REMOTE2 with askpass + named errors
  + origin-URL assertion, comment updates.
- `.env.sample` — document APP_REPO_GIT_TOKEN.
- `README.md` — private-repo paragraph in setup, app-contract comment tweak.
