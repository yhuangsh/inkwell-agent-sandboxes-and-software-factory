# Port teardown delta-tar speedup from sssf-sbx

## Goal

Replace the slow whole-tree uncompressed artifact tar in THIS repo's
`just/sandbox/lifecycle/teardown.just` with the proven gzipped git-delta tar from
`~/playground/sssf-sbx` at commit `2fb291e` ("Delta-tar teardown artifacts instead
of shipping the whole factory tree").

Measured motivation (from the reference, on the ~16KB/s dal-region link): the old
`tar cf - $P` shipped 9.95MB ≈ 10 minutes of teardown, even when the run's
factory-tree delta was zero bytes — the host already owns every
tracked-and-unmodified byte by construction (same clone sha; mount gate A asserts
a clean tree before the run).

## File to touch

**Exactly one file: `just/sandbox/lifecycle/teardown.just`** — and only the
"── 1. artifacts ──" block inside the `teardown RUN_ID *FLAGS:` recipe. Nothing
else in the file changes: harvest-first + abort-on-failed-harvest, the
`--no-harvest` flag handling, destroy, record close, and every existing message
shape stay byte-identical.

## Reference (read it first)

```
cd ~/playground/sssf-sbx && git show 2fb291e:just/sandbox/lifecycle/teardown.just
```

(Already mirrored to `/tmp/ref_teardown.just` by the planner — but re-read from
git to be safe.)

## The change

Replace this block (current repo, artifacts section):

```bash
    # ── 1. artifacts ------------------------------------------------------------
    if [ "$VM_ALIVE" = 1 ]; then
        mkdir -p "$ART"
        TAR_TMP=$(mktemp "${TMPDIR:-/tmp}/sbx-$RUN_ID.XXXXXX")
        # One round trip, and `ls -d` filters to what actually exists so a run that
        # died before writing app_docs/ (or before the target clone) is not an error.
        ssh "${SSH_OPTS[@]}" "$VM".exe.xyz \
            "cd app 2>/dev/null || exit 0; P=\$(ls -d $TAR_PATHS 2>/dev/null); [ -z \"\$P\" ] && exit 0; tar cf - \$P" \
            > "$TAR_TMP" || true
        if [ -s "$TAR_TMP" ]; then
            tar xf "$TAR_TMP" -C "$ART"
            echo "   artifacts -> $ART"
        else
            echo "   artifacts: none found on the vm"
            rmdir "$ART" 2> /dev/null || true   # do not leave an empty dir implying we pulled something
        fi
        rm -f "$TAR_TMP"
    else
        echo "   artifacts: skipped (no vm)"
    fi
```

with the reference's delta-tar version, reconciled per the prompt:

```bash
    # ── 1. artifacts ------------------------------------------------------------
    # WHY a DELTA tar instead of the whole tree: the previous command here
    # (`tar cf - $TAR_PATHS`, uncompressed) shipped EVERY byte of specs/ and
    # app_docs/ — MEASURED 9.95MB on a real box whose run changed nothing in the
    # factory tree. Over that box's dal-region link (~16KB/s) that is ~10 minutes
    # of teardown spent transferring bytes the host ALREADY owns: it cloned the
    # same sha and mount gate A asserts the factory tree was clean before the run,
    # so every tracked-and-unmodified byte is reconstructible here by construction.
    # The only unique bytes are the run-delta under the tar paths (untracked
    # non-ignored + HEAD-modified files — MEASURED ZERO files on that box) plus the
    # gitignored always-files git cannot report (sssf.db, traced to 56KB, run.log,
    # target manifest). Send just those, gzip the tiny payload, and skip the
    # transfer entirely when the delta is empty.
    if [ "$VM_ALIVE" = 1 ]; then
        mkdir -p "$ART"
        TAR_TMP=$(mktemp "${TMPDIR:-/tmp}/sbx-$RUN_ID.XXXXXX")
        # One round trip. $TAR_PATHS expands on the HOST and is passed as argv;
        # ssh does not pass argv (it joins args into one string the remote login
        # shell re-parses), so the space-separated list arrives as MANY positional
        # args and is rejoined with "$*" — $1 alone would silently be just "specs".
        # Everything else stays literal on the VM (heredoc — no quote gymnastics).
        # `--diff-filter=d` drops DELETED files: they have no bytes to ship and
        # would make `tar -T` fail on a name that does not exist. Iterating the tar
        # paths with `[ -f ]` picks up the gitignored always-files and skips the
        # two directories. An empty list prints the sentinel to STDERR (stdout is
        # the tar stream) and exits 0 with empty stdout; the host then skips the
        # transfer but the artifacts dir stays created. git in a weird state (no
        # HEAD, corrupt index) degrades to the always-files rather than failing.
        ssh "${SSH_OPTS[@]}" "$VM".exe.xyz bash -s -- "$TAR_PATHS" <<'REMOTE' \
            > "$TAR_TMP" || true
        set -uo pipefail
        paths="$*"; cd app 2> /dev/null || exit 0
        list=$(mktemp)
        { git ls-files --others --exclude-standard -- $paths 2> /dev/null
          git diff --name-only --diff-filter=d HEAD -- $paths 2> /dev/null; } >> "$list"
        for f in $paths; do [ -f "$f" ] && echo "$f" >> "$list"; done
        sort -u -o "$list" "$list"
        if [ -s "$list" ]; then
            tar czf - -T "$list"
        else
            echo "no run artifacts to pull — factory tree unchanged" >&2
        fi
        rm -f "$list"
    REMOTE
        if [ -s "$TAR_TMP" ]; then
            tar xzf "$TAR_TMP" -C "$ART"
            echo "   artifacts -> $ART"
        else
            echo "   artifacts: none found on the vm"
            rmdir "$ART" 2> /dev/null || true   # do not leave an empty dir implying we pulled something
        fi
        rm -f "$TAR_TMP"
    else
        echo "   artifacts: skipped (no vm)"
    fi
```

### Reconciliation notes (both already applied in the snippet above)

1. **Remote script = reference exactly.** Gzipped git-delta tar: union of
   `git ls-files --others --exclude-standard` and
   `git diff --name-only --diff-filter=d HEAD` under `$TAR_PATHS`, plus the
   always-files found on disk (`adws/adw_data/sssf.db`, `run.log`,
   `target/sssf.app.yaml` — whatever of `$TAR_PATHS` is a plain file). Empty delta
   → sentinel on STDERR, empty stdout, exit 0. The ssh argv-joining gotcha is
   handled by the heredoc `bash -s -- "$TAR_PATHS"` + remote `paths="$*"` rejoin —
   do NOT "simplify" this back to a one-line `ssh ... "command"` string.
2. **Host side keeps THIS repo's empty-tar handling.** The reference has no
   `else` branch; this repo does (`artifacts: none found on the vm` + `rmdir` of
   the empty artifacts dir). KEEP it — the empty-delta sentinel arrives as empty
   stdout, `$TAR_TMP` is zero bytes, and the existing else fires cleanly.
   Note `tar xzf` (not `tar xf`) on the extract to match the gzipped stream.
3. **`$TAR_PATHS` construction above the block is unchanged** — it already
   produces `specs app_docs adws/adw_data/sssf.db run.log [target/sssf.app.yaml]`,
   which is exactly what the remote delta script consumes.

### Gotchas

- This file is `import`ed into the root justfile and shares one scope with five
  other phase files — no new file-level variables, no `set` lines. All new names
  (`list`, `paths`) live inside the remote heredoc and are fine.
- The heredoc terminator `REMOTE` must appear at the recipe's indentation level
  exactly as in the reference (leading whitespace inside a recipe is passed
  through; match the reference file's layout character-for-character — copy the
  block, don't retype it).
- Do not touch harvest.just, the provisioner, README, or the parked items.

## Verification (real, on a live VM — all timings recorded in the envelope)

Use the default roster (`adws/adw_sssf_config/sssf.config.yaml`: inkwell, target
mode — `app.repo: https://github.com/yhuangsh/inkwell.git`, `path: target`,
`manifest: sssf.app.yaml`).

(a) **Fresh armed mount, gates A–E green:**
    ```
    just sbx mount <RUN_ID>          # create + fill + setup; setup gates A-E must pass
    ```

(b) **(d) FIRST, while the tree is still clean — empty-delta sentinel proof.**
    Before executing any run on this VM, its factory tree is clean by gate A, so
    run the remote delta script by hand and observe the sentinel:
    ```
    VM=$(sandbox_mount/host/run_record.py get <RUN_ID> vm_name)
    ssh -o BatchMode=yes "$VM".exe.xyz bash -s -- \
        specs app_docs adws/adw_data/sssf.db run.log target/sssf.app.yaml \
        > /tmp/delta-out.bin 2> /tmp/delta-err.txt <<'REMOTE'
        set -uo pipefail
        paths="$*"; cd app 2> /dev/null || exit 0
        list=$(mktemp)
        { git ls-files --others --exclude-standard -- $paths 2> /dev/null
          git diff --name-only --diff-filter=d HEAD -- $paths 2> /dev/null; } >> "$list"
        for f in $paths; do [ -f "$f" ] && echo "$f" >> "$list"; done
        sort -u -o "$list" "$list"
        if [ -s "$list" ]; then
            tar czf - -T "$list"
        else
            echo "no run artifacts to pull — factory tree unchanged" >&2
        fi
        rm -f "$list"
    REMOTE
    cat /tmp/delta-err.txt          # expect the sentinel line
    wc -c /tmp/delta-out.bin        # expect a small gzip (always-files only) or 0
    ```
    Note: `sssf.db`/`run.log`/`sssf.app.yaml` are always-files present on disk, so
    on a clean tree stdout is a *tiny* gzip of just those — NOT zero. The true
    zero-byte case is when none of the always-files exist (e.g. pre-fill); either
    way, demonstrate and report: sentinel-on-stderr + no tree delta shipped. If the
    always-files are present, additionally prove the delta semantics by showing
    `tar tzf /tmp/delta-out.bin` contains ONLY the always-files, no specs/app_docs.

(c) **Run that produces artifacts:**
    ```
    just sbx lifecycle execute <RUN_ID> sdlc \
      "write a one-paragraph design note to specs/ and a matching app_docs note"
    ```
    Verify on the VM (or via the resulting delta) that at least one new file under
    `specs/` and one under `app_docs/` exist.

(d) **Timed end-to-end teardown:**
    ```
    time just sbx lifecycle teardown <RUN_ID>
    ```
    Expect seconds to ~1 minute total (was ~10 min). Then assert:
    - `.sandbox/runs/<RUN_ID>-artifacts/` contains: the run's NEW `specs/` and
      `app_docs/` files, `adws/adw_data/sssf.db`, and
      `target/sssf.app.yaml` (the target manifest).
    - Harvest bundle verifies:
      ```
      git bundle verify .sandbox/runs/<RUN_ID>.bundle
      ```
    - Message shapes unchanged: `artifacts -> ...`, `vm: destroyed`,
      `record closed`, `✓ teardown complete`.
    - Host tree clean afterwards (`git status`).

Report the real elapsed time for (d) and the payload sizes from (b) in the final
envelope.

## Out of scope

Harvest bundle mechanics, provisioner, README, the parked items.

## Done means

Port landed by this chain (one file: `just/sandbox/lifecycle/teardown.just`),
(a)–(d) demonstrated with real timings, tree clean. The chain's commit phase owns
the commit; builder leaves work dirty.
