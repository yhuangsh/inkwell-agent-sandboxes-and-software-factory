# Plan: Repoint sandbox factory clone source to the engineer's fork

## Goal

Make the sandbox factory self-sufficient: `just sbx mount` fills the VM by
cloning from the engineer's public fork instead of disler's original repo.
One-line change; no provisioning logic, credentials, or mount-chain shape
changes.

## Context (verified during planning)

- `just/sandbox/lifecycle/fill.just` line 25 is the ONLY place the clone
  source is named:
  ```
  REPO="https://github.com/disler/inkwell-agent-sandboxes-and-software-factory.git"
  ```
  Other "disler" hits in the tree are historical specs, HTML artifacts, and
  session logs — not clone sources. Leave them.
- `git ls-remote https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git refs/heads/main`
  returns `c6e701e1ad777a3f7f1dcba2091d689083e4b946` — the fork is public
  (cloneable with no credentials) and its main carries all 9 fix commits,
  including the fixed `provision.sh` and (after this change lands and is
  pushed) the repointed fill.just.
- The recipe above the URL already comments "Public repo: no auth, no GitHub
  integration" — the fork keeps that property, so the surrounding flow is
  untouched.

## Change

File: `just/sandbox/lifecycle/fill.just`, line 25.

Replace:
```
REPO="https://github.com/disler/inkwell-agent-sandboxes-and-software-factory.git"
```
with:
```
REPO="https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git"
```

Also update the comment immediately above it so the comment names the fork
(it currently just says "Public repo: no auth, ..." — keep that sentence and
add/adjust a phrase noting the source is the engineer's public fork carrying
the fix commits, so future readers know why it's not upstream). Keep it to
one line of comment.

Nothing else in the file changes. Do NOT touch: provisioning logic
(`provision.sh`), anything credential-related, the mount chain, any upstream
sync tooling.

## Post-change step (required for the "Done" condition)

The Done condition is: a fresh `git clone` of the **fork's** main contains
the repointed fill.just AND the fixed provision.sh. That means the change
must land on the fork's main:

1. Commit the change on main (or current working branch — check `git status`
   / branch first; follow the repo's normal convention).
2. Push to the fork remote. Check `git remote -v`: if `origin` already points
   at `yhuangsh/inkwell-agent-sandboxes-and-software-factory`, a plain
   `git push` suffices. If origin is the disler repo and the fork is another
   remote (e.g. `fork` or `yhuangsh`), push there instead. Do not attempt to
   push to disler's repo — no push access from this machine.
3. Re-verify after push:
   `git ls-remote https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git refs/heads/main`
   returns the new commit, and a scratch clone confirms the content:
   ```
   tmp=$(mktemp -d)
   git clone --quiet https://github.com/yhuangsh/inkwell-agent-sandboxes-and-software-factory.git "$tmp/app"
   grep 'yhuangsh' "$tmp/app/just/sandbox/lifecycle/fill.just"   # must match
   grep -n 'pi@latest\|npm install' "$tmp/app/just/sandbox/lifecycle/provision.sh"  # sanity: fixed provision.sh present
   rm -rf "$tmp"
   ```
   (Clone scratch goes to /tmp via mktemp, never into the repo.)

## Verification

- Static: `grep -rn "github.com/disler" just/ | grep REPO` returns nothing;
  `grep -n "yhuangsh" just/sandbox/lifecycle/fill.just` shows line ~25.
- `just --version` sanity + optionally `just --list` to confirm the justfile
  still parses (the change is inside a bash recipe string, so parse risk is
  nil, but cheap to confirm).
- Post-push scratch-clone check as above proves the fresh-machine path.
- Full end-to-end `just sbx mount <run-id>` (gates A–E) is the real proof but
  requires VM provisioning; run it only if the operator asks — the prompt's
  Done is defined at the clone level.

## Out of scope (do not do)

- Provisioning logic changes
- Any credential on the VM
- Mount chain shape
- Upstream (disler) sync
