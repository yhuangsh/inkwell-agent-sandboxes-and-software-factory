# Plan: setup.just provisioner coherence comment + clone-skew warning

adw_id: `66a6e90a`
Scope: **one file only** — `just/sandbox/lifecycle/setup.just`. Two changes, no
behavior change to provisioning itself. The sentinel/gate flow stays untouched.

## Background

The `setup` recipe streams the HOST working-tree `sandbox_mount/guest/provision.sh`
into the sandbox over ssh stdin (never the VM clone's copy). The comments justify
this with an obsolete rationale — "the clone comes from a third-party public repo
this machine cannot push to". Origin is now the engineer's fork and receives
constant pushes. The mechanism stays for the real reason: **provisioner/gate
coherence** — gates A–E are host-side, so the provisioner version that runs must
equal the gate version that checks its work; streaming the host copy guarantees
that even when origin lags.

## Change 1 — replace the stale rationale in the header comment

In `just/sandbox/lifecycle/setup.just`, the top-of-file header comment (lines
~6–14) contains:

> (never the stale copy inside the VM's clone — the clone comes
> from a third-party public repo this machine cannot push to, and gate A forbids
> writing into the tracked app/ tree, so host-streaming is the only path a local
> provisioner fix can take)

Rewrite that parenthetical to state the coherence rationale, e.g.:

> (never the copy inside the VM's clone — the gates A–E below are
> host-side, so the provisioner that runs must be the same version as the gate
> that checks its work; origin is the engineer's fork and may lag the working
> tree, so host-streaming is what keeps provisioner and gate in lockstep)

The same stale claim ("a third-party public repo this machine cannot push to")
also appears in the inline comment block directly above the streaming ssh line
(in the `── 1. provision ──` section). Update that sentence to the same
coherence rationale so the two comments agree. Do not otherwise reword or
restructure comments; keep the surrounding prose (sentinel clearing, stdin
redirect explanation, PROVISION_REPO_ROOT quoting) intact.

## Change 2 — informational sha256 divergence warning after the stream

Immediately AFTER the existing streaming block:

```bash
"${SSH[@]}" 'PROVISION_REPO_ROOT="$HOME/app" bash -s' < sandbox_mount/guest/provision.sh \
  || gate_fail "provision.sh exited non-zero (its last '── step ──' line names the stage)"
```

add a divergence check that:

1. Computes the host copy's sha256:
   `HOST_PROV_SHA=$(sha256sum sandbox_mount/guest/provision.sh | awk '{print $1}')`
2. Reads the clone copy's sha256 inside the VM (clone lives at `~/app`, ssh
   default cwd is `$HOME`, consistent with gate A's `cd "$HOME/app"`):
   `"${SSH[@]}" 'sha256sum app/sandbox_mount/guest/provision.sh' < /dev/null`
   piped through `awk '{print $1}'`, wrapped so a missing file or ssh blip
   yields an empty string and never aborts (`|| true`, since `set -euo pipefail`
   is in effect).
3. If the clone sha is non-empty and differs, print EXACTLY one warning line in
   this shape and CONTINUE:

   ```
   [setup] WARN: host provisioner <sha8> differs from the clone copy <sha8> — origin may lag the host
   ```

   where `<sha8>` is the first 8 chars of each hash (`${VAR:0:8}`).
4. If the clone copy is missing/unreadable, either stay silent or print a
   clearly-named informational line — but never call `gate_fail` and never exit
   non-zero from this block. Skew is informational, never a failure.

Add a brief comment above the check explaining: the host copy is authoritative
(gate coherence), the comparison only surfaces that origin may lag the host, and
it is deliberately outside the gate.

Do NOT touch: the sentinel section (`── 2. sentinel ──`), the gate sections
(A–E), `gate_fail`, or any other file.

## Git rules (engineer's standing rule)

- No `git commit`, `git push`, `git checkout`, `git branch`, `git reset`, or any
  ref mutation. The chain's commit phase owns the commit.
- `git add` is allowed. Leave the tree dirty.
- `changed_files` lists only `just/sandbox/lifecycle/setup.just`.

## Verification (all must pass)

1. `just --list` exits 0 (justfile still parses).
2. Recipe body passes `bash -n`: extract the `setup` recipe's bash (e.g.
   `just --show setup` / sed the recipe body) into `/tmp` and run `bash -n` on
   it. Scratch files go to `/tmp`, never the repo.
3. Demonstrate the divergence warning with a local dry-run: in `/tmp`, create
   two files with different contents, run the comparison/warning snippet against
   them, and show the `[setup] WARN:` line fires with two different sha8 values;
   also run it with identical files and show no warning. Paste the dry-run
   output into the builder's report.
4. Confirm no other file was modified: `git status --porcelain` shows only
   `just/sandbox/lifecycle/setup.just` (plus any pre-existing dirty files that
   were already there — do not touch them).

## Out of scope

- Every other file.
- The parked items: ref-guard, rollback-index, deleted_files.
- Any behavior change to provisioning (the stream, sentinel, and gate A–E
  semantics are byte-for-byte the same).
