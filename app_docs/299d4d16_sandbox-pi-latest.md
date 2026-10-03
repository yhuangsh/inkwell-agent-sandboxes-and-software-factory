# `just sbx mount` provisions the latest published pi agent

The done-condition for a mounted sandbox now is precise: `pi --version` inside
the VM equals what `npm view @earendil-works/pi-coding-agent version` reports
on the host at mount time. Two gaps previously let a stale `pi` slip past the
mount and the gate — a shadowed binary on PATH, and a gate that never checked
the version. Both are now closed.

## Why it matters

`@earendil-works/pi-coding-agent` is the binary every ADW runs against, so a
stale `pi` on the VM means a stale factory: providers, built-in tools, and
cost table all drift from what the host's "latest" thinks is true. The
exeuntu image bakes an old native `pi` and ships no node/npm, and the baked
binary refuses to self-update (`pi update` fails at `/$bunfs/root/pi`). A
`npm install -g` on the host runs into the same PATH shadowing that step 2
already documented for `bun`. The result was a "succeeded" mount with a
`pi` that wasn't the one `just sbx mount` claimed to install.

## What changed

### `sandbox_mount/guest/provision.sh` — step 4/9 rewritten

The exeuntu image ships no node/npm, so the step first drops a standalone Node
22 into `$HOME/.local/node` (curl + tar from `nodejs.org/dist/latest-v22.x/`,
no apt) and symlinks `node`/`npm`/`npx` into `/usr/local/bin` so every future
non-interactive `ssh vm cmd` finds them. A fast re-run check
(`[[ -x "$NODE_DIR/bin/node" ]]`) skips the download when Node is already
bootstrapped.

The `pi` install itself is hardened:

- Resolves `LATEST="$(npm view "$PI_PKG" version)"` once and installs
  `"$PI_PKG@$LATEST"` (not `@latest`) — a second dist-tag resolution could
  land a version the compare above just rejected.
- `NPREFIX="$(npm prefix -g)"` then `sudo ln -sf "$NPREFIX/bin/pi"
  /usr/local/bin/pi` runs **unconditionally** (not "only when `command -v pi`
  differs"): this script has `$NODE_DIR/bin` prepended on PATH, so a stale
  baked binary at `/usr/local/bin/pi` can pass `command -v pi` here while
  shadowing the npm install for any future shell. `/usr/local/bin` precedes
  `/usr/bin` and the user npm prefixes, so the symlink wins every shadow
  fight. `hash -r` clears the current shell's hashed path so the post-symlink
  `command -v` resolves correctly.
- The step closes with a **hard assertion**:
  `[[ "$(pi --version 2>/dev/null)" == "$LATEST" ]] || exit 1`. A registry
  outage or a still-stale binary now fails the mount instead of printing
  the old version and moving on.

The step number ("4/9"), the `step`/`say` style, the ERR trap contract, and
the `touch /tmp/PROVISION_READY` sentinel at the literal end of the file are
all preserved. The "never apt" rule stays in force (only `bun`, `just`,
and `node` come from outside the image).

### `just/sandbox/lifecycle/setup.just` — gate assertion B extended

The REMOTE_B heredoc now does version parity after the existing `command -v
pi` check:

```bash
want="$(npm view @earendil-works/pi-coding-agent version)" || { echo "   npm view failed — cannot verify pi currency"; exit 1; }
got="$(pi --version 2>/dev/null || true)"
[ "$got" = "$want" ] || { echo "   pi is $got, registry latest is $want — provision step 4 did not land latest"; exit 1; }
echo "   pi $got matches registry latest"
```

The heredoc is `<<'REMOTE_B'` (quoted, no host expansion), so `npm view`
runs remotely, against the same registry provision queried at provision
time. The `[gate] B PASS` message and the `gate_fail` text now mention
staleness; the "five-assertion health gate" count is unchanged — B absorbs
the version check rather than adding a sixth.

Defense in depth: the provision assertion catches a bad install at provision
time; the gate assertion catches a re-run of `setup` on an older VM, and
makes the done-condition observable from the host by running `just sbx
mount`.

### `just/sandbox/mount.just` — unchanged

The chain (`create → fill → setup → observe`) already runs `setup`, which
runs provision.sh and the gate. No edit was needed.

### `specs/299d4d16_sandbox-pi-latest.md` — new file

A planning spec capturing the gaps and the chosen fixes (rooted in the
verified host numbers: `pi --version` → `1.0.0`, `npm view ... version` →
`1.0.1` at planning time).

## How to verify

1. **Static** — `bash -n sandbox_mount/guest/provision.sh` parses; `just
   --summary` (or `just sbx lifecycle setup` with no args) shows the
   recipes still resolve.
2. **Live** —
   - `just sbx mount <run-id>` on a fresh sandbox.
   - `[gate] B PASS` line includes the version-parity line.
   - `ssh <vm>.exe.xyz 'pi --version'` output equals
     `npm view @earendil-works/pi-coding-agent version` run on the host.
3. **Negative check (cheap)** — on the mounted VM, install an older version
   with `ssh <vm>.exe.xyz 'sudo npm install -g
   @earendil-works/pi-coding-agent@<older>'`, then re-run
   `just sbx lifecycle setup <run-id>`. Provision must upgrade it back and
   the gate must pass with the latest version.
4. **Cleanup** — `just sbx lifecycle teardown <run-id>`.

## Files

- `sandbox_mount/guest/provision.sh` — step 4/9 (Node bootstrap, hard
  post-install assertion, unconditional `/usr/local/bin/pi` symlink).
- `just/sandbox/lifecycle/setup.just` — gate assertion B heredoc and
  surrounding echo/gate_fail text.
- `specs/299d4d16_sandbox-pi-latest.md` — the planning spec (new).
- `just/sandbox/mount.just` — referenced only; no change.