# Plan: `just sbx mount` provisions the latest published pi agent

## Goal

After `just sbx mount <run-id>` completes, `pi --version` inside the sandbox
reports exactly the version that `npm view @earendil-works/pi-coding-agent
version` reports on the host at that moment. No pinning, no version file —
always the live latest.

## Current state (verified during planning)

- `sandbox_mount/guest/provision.sh` step `4/9 pi agent (latest)` already tries
  to do this: it compares `pi --version` to `npm view ... version` and runs
  `npm install -g "$PI_PKG@latest"` on mismatch.
- `pi --version` prints a bare semver (`1.0.0`), so the string comparison with
  `npm view` is sound. Confirmed on the host: `pi --version` → `1.0.0`,
  `npm view @earendil-works/pi-coding-agent version` → `1.0.1`.

### The two gaps that let a stale pi survive a mount

1. **Shadowed binary, no post-install verification.** The exeuntu image may
   bake an old `pi` onto PATH (the step's own comment says so). After
   `npm install -g`, the corrective symlink into `/usr/local/bin` only fires
   when `command -v pi` finds NOTHING — but an image-baked `pi` means
   `command -v pi` succeeds, so the symlink is skipped and the old binary can
   keep shadowing the freshly installed one (e.g. baked at `/usr/local/bin/pi`
   while npm's global prefix is `~/.npm-global`, or vice versa with PATH
   order). The step ends with `say "pi $(pi --version)"` but never ASSERTS the
   version — a stale pi prints its old version and provisioning succeeds.
2. **No gate coverage.** `just/sandbox/lifecycle/setup.just` assertions B and
   the C/D/E block check that `pi` exists, lists models, pings the roster,
   reports cost, and has credentials — nothing checks the VERSION. A stale pi
   passes the whole gate, so `just sbx mount` reports success while the
   done-condition is false.

Minor: `npm install -g "$PI_PKG@latest"` resolves the `latest` dist-tag a
second time (after `npm view` already resolved it). Installing the exact
resolved version `@$LATEST` removes any window for tag movement or cache
disagreement between the two resolutions.

## Changes

### 1. `sandbox_mount/guest/provision.sh` — rewrite step 4/9

Keep the step number, the `step`/`say` style, the ERR trap contract, and the
skip-if-current fast path. Restructure the body to:

1. `command -v npm` guard — unchanged (image must ship node/npm).
2. `LATEST="$(npm view "$PI_PKG" version)"` — unchanged source of truth.
3. `CUR="$(pi --version 2>/dev/null || echo none)"`; if equal, `say` and skip —
   unchanged fast path.
4. On mismatch: `npm install -g "$PI_PKG@$LATEST" || sudo npm install -g
   "$PI_PKG@$LATEST"` — install the EXACT version `npm view` resolved, not the
   `@latest` tag.
5. **Always reconcile the PATH-visible binary with the npm-global install, not
   only when `pi` is missing from PATH:** resolve `NPREFIX="$(npm prefix -g)"`;
   if `$NPREFIX/bin/pi` exists and `command -v pi` does not resolve to that
   exact path (or `pi --version` != `$LATEST`), `sudo ln -sf "$NPREFIX/bin/pi"
   /usr/local/bin/pi` and `hash -r`. `/usr/local/bin` precedes `/usr/bin` and
   the user npm prefixes in every non-interactive ssh shell, so this wins any
   shadow fight against an image-baked binary.
6. **Hard assertion to close the step:** after install/symlink,
   `[[ "$(pi --version 2>/dev/null)" == "$LATEST" ]] || { echo "[provision] pi
   is at $(pi --version 2>/dev/null || echo missing), registry latest is
   $LATEST" >&2; exit 1; }`. This replaces the passive `say "pi $(...)"` as
   the step's verdict (keep a `say` of the final version too). A registry
   outage or a shadowed binary now FAILS the mount instead of passing with a
   stale pi.

Nothing else in the file changes: steps 1–3 and 5–9, the sentinel
(`touch /tmp/PROVISION_READY` stays the literal last line), and the "never
apt" constraint are untouched.

### 2. `just/sandbox/lifecycle/setup.just` — extend gate assertion B with version parity

Inside the existing `REMOTE_B` heredoc (assertion B, "pi --list-models is
non-empty"), after the existing `command -v pi` check add:

```bash
want="$(npm view @earendil-works/pi-coding-agent version)" || { echo "   npm view failed — cannot verify pi currency"; exit 1; }
got="$(pi --version 2>/dev/null || true)"
[ "$got" = "$want" ] || { echo "   pi is $got, registry latest is $want — provision step 4 did not land latest"; exit 1; }
echo "   pi $got matches registry latest"
```

Update the surrounding echo lines: the `[gate] B PASS` message becomes
"pi current and models listed" (or similar); the `gate_fail` message for B
mentions staleness as a failure mode. Keep it inside B rather than adding a
sixth assertion — B already proves `pi` is on PATH, and the header comment
"five-assertion health gate" stays accurate (adjust the comment wording only
if it enumerates what B checks; the count does not change).

Why the gate also checks (defense in depth): the provision assertion catches a
bad install at provision time; the gate assertion catches a re-run of `setup`
on an older VM, and makes the done-condition observable from the host by
simply running `just sbx mount`.

### 3. `just/sandbox/mount.just` — NO change

The chain (create → fill → setup → observe) already runs `setup`, which runs
the provisioner and now the version assertion. Listing it here only to confirm
it needs no edit.

## Out of scope (per request)

- What gets mounted, teardown, pinning a pi version — untouched.
- No `models.json`, no registry mirror work.
- No apt in provision.sh.

## Verification

1. Static: `bash -n sandbox_mount/guest/provision.sh`; `just --summary` (or
   `just sbx lifecycle setup` with no args showing usage) to prove the
   justfiles still parse.
2. Live (the done-condition):
   - `just sbx mount <run-id>` on a fresh sandbox; expect `[gate] B PASS` to
     include the version-parity line.
   - `ssh <vm>.exe.xyz 'pi --version'` output equals
     `npm view @earendil-works/pi-coding-agent version` run on the host.
   - Negative check (optional but cheap): on the mounted VM,
     `ssh <vm>.exe.xyz 'sudo npm install -g @earendil-works/pi-coding-agent@<older>'`
     then re-run `just sbx lifecycle setup <run-id>` — provision must upgrade
     it back and the gate must pass with the latest version.
3. Teardown the test sandbox afterward: `just sbx lifecycle teardown <run-id>`.

## Risks / notes for the builder

- `npm view` inside the sandbox requires registry egress; the sandbox already
  needs egress for provider APIs and provision already runs `npm view`, so
  this adds no new dependency.
- The ERR trap in provision.sh uses `STEP`; keep the step name string
  "4/9 pi agent (latest)" (or update it in the single `step` call only).
- Do not let the new assertion's failure bypass the trap/sentinel contract: a
  plain `exit 1` inside the step body is correct — the trap reports the step
  and `/tmp/PROVISION_READY` is never touched, so setup's sentinel poll fails
  fast via the provision exit code.
- In setup.just, heredocs are `<<'REMOTE_B'` (quoted, no host expansion) —
  the added lines must not reference host-side variables.
