# Land the models.json-optionality fix in agent_pi.py

Session: `77f0e46d`. One-file factory fix, evidence-backed, diff already preserved.
Roster: `adws/adw_sssf_config/sssf.meta2.config.yaml` (builder `writes:` authorizes
**exactly** `adws/adw_modules/agent_pi.py` and that roster file — nothing else).

## Background (evidence, already established — do NOT re-prove the crash)

- Run `d142f7cb` reproduced the bug on a fresh exe.dev box: FILL deletes
  `~/.pi/agent/models.json` (`just/sandbox/lifecycle/fill.just:190`), and
  `agent_pi.context_window()` then raised
  `FileNotFoundError: '/home/exedev/.pi/agent/models.json'` at
  `adws/adw_modules/agent_pi.py:110`, crashing every in-sandbox SDLC. Seeding
  `{"providers":{}}` made the identical run pass 3/3. Documented in
  `adws/adw_data/sessions/d142f7cb/builder/envelope.json`.
- The exact fix is preserved at `/tmp/agent_pi_models_json_optional.patch`.
  **Planner has already run `git apply --check` against current HEAD: it applies
  cleanly.** Current HEAD = `a0653cc` = `origin/main`; the only untracked path
  is the roster `sssf.meta2.config.yaml` (staged by the operator for this run).

## The fix (the whole code change)

In `adws/adw_modules/agent_pi.py`, `context_window()` must treat `models.json`
as the OPTIONAL local override it is: wrap the read in
`try/except (OSError, ValueError)` → `registry = {}`, falling through to
`_pi_catalog()` (which reads the same merged view from pi's built-in catalog).
After the edit the function is exactly:

```python
def context_window(provider: str, model_id: str) -> int:
    """The model's context ceiling from pi's merged model catalog.

    `models.json` is an OPTIONAL local override: FILL removes it on a fresh box
    (the mirror-free rosters rely on pi's built-in catalog), so its absence is
    the normal case, not an error. A missing or malformed file falls through to
    `_pi_catalog()`, which reads the same merged view straight from pi.
    """
    try:
        registry = json.loads(Path(MODELS_JSON).read_text())
    except (OSError, ValueError):
        registry = {}
    for model in registry.get("providers", {}).get(provider, {}).get("models", []):
        if model.get("id") == model_id:
            return int(model.get("contextWindow") or 0)
    for listed_provider, listed_model, window in _pi_catalog():
        if listed_provider == provider and listed_model == model_id:
            return window
    return 0
```

## Step 1 — Apply the fix

```bash
git apply --check /tmp/agent_pi_models_json_optional.patch && \
git apply /tmp/agent_pi_models_json_optional.patch
```

If `git apply` fails for any reason, re-implement the diff above identically
with the edit tool. No other hunk, no other file. Verify:
`git diff --stat` shows exactly `adws/adw_modules/agent_pi.py | 11 ++++++++++-`.

## Step 2 — Host smoke (missing + malformed both tolerated)

`MODELS_JSON` is env-overridable via `PI_MODELS_PATH` (agent_pi.py:23), so both
failure modes are testable on the host without touching the real file. Run each
in a SEPARATE process (`_pi_catalog` is `lru_cache`d):

```bash
uv run python -m py_compile adws/adw_modules/agent_pi.py

# missing file → no FileNotFoundError, falls through to _pi_catalog()
PI_MODELS_PATH=/tmp/definitely-absent-models.json \
  uv run python -c 'from adws.adw_modules.agent_pi import context_window; print("missing:", context_window("deepseek", "deepseek-flash"))'

# malformed JSON → no JSONDecodeError, same fall-through
printf '{not json' > /tmp/malformed-models.json
PI_MODELS_PATH=/tmp/malformed-models.json \
  uv run python -c 'from adws.adw_modules.agent_pi import context_window; print("malformed:", context_window("deepseek", "deepseek-flash"))'
```

Assert: both calls return without raising and print an int (host pi is
installed, so `_pi_catalog()` resolves the built-in deepseek catalog — a
positive int is expected; the hard requirement is **no exception**). Clean up
the /tmp scratch files afterwards. Scratch stays in `/tmp`, never in the repo.

## Step 3 — Commit (spec commit, then fix commit; d142f7cb precedent)

1. Spec commit (mirrors 6238bb0 — the planner's spec is the record of what was
   asked; committing it is how the tree ends clean):
   `git add specs/77f0e46d_models-json-optional.md && git commit -m "Add spec for the agent_pi models.json-optionality landing"`
2. Fix + roster in one commit (mirrors a0653cc — the authorization ships with
   the commit it enables):
   `git add adws/adw_modules/agent_pi.py adws/adw_sssf_config/sssf.meta2.config.yaml && git commit -m "Make agent_pi context_window tolerate missing or malformed models.json"`

`git status --short` must now be empty.

## Step 4 — Publish a temp verification branch

FILL clones `origin/main`, which does not yet carry the fix, so the fork must
serve it — same mechanism d142f7cb used:

```bash
git ls-remote origin | grep sssf-verify || true   # pick a free name, e.g. sssf-verify-mjo
git branch sssf-verify-mjo                         # branch at HEAD, nothing else
git push -u origin sssf-verify-mjo
TEMP_SHA=$(git rev-parse HEAD)
```

Do NOT push `main` yet — it is pushed in Step 6 only after the fix is proven.

## Step 5 — Pinned verification: the fix on a virgin box

```bash
just sbx lifecycle create sssfmjo
ID=$(sandbox_mount/host/run_record.py list | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["run_id"])')
just sbx lifecycle fill "$ID" "$TEMP_SHA"
just sbx lifecycle setup "$ID"      # gates A-E all PASS
just sbx lifecycle observe "$ID"    # app 200
```

Then the actual assertion — **no models.json anywhere, no seeding**:

1. Precondition: `just sbx run cmd "$ID" 'ls -la ~/.pi/agent/'`
   → `models.json` ABSENT (fill.just:190 deleted it). If it is present, stop:
     the box is not virgin and the proof is invalid.
2. Execute the in-sandbox SDLC via the execute lane:
   `just sbx lifecycle execute "$ID" "Add a small footer word-count badge to the inkwell editor" "" build-test`
   then follow `just sbx run cmd "$ID" 'tail -f run.log'`.
3. EXPECT (this is the whole point of the run): the chain completes all 3
   phases, `status: success` — the crash site `agent_pi.context_window` now
   falls through to pi's built-in catalog instead of raising
   `FileNotFoundError`. The quality gate runs manifest-driven from the app dir
   (`quality tests: bun test server.test.ts`, `passed: True`, artifacts under
   `/home/exedev/app/adws/adw_data/sessions/<adw>/context_handoff/quality/`).
   Any `FileNotFoundError`/`JSONDecodeError` from `context_window` = FAILURE:
   capture the traceback, teardown, and stop the chain.
4. `just sbx lifecycle teardown "$ID"`.

## Step 6 — Push main, delete the temp branch

The done-condition requires a fresh plain `just sbx mount` (which clones
`origin/main`) to carry the fix — so once Step 5 is green:

```bash
git push origin main                      # fast-forward: spec + fix commits only
git push origin --delete sssf-verify-mjo
git branch -D sssf-verify-mjo
```

## Step 7 — Letter-of-the-bar final run: plain mount, virgin box

```bash
just sbx mount sssfmjo2                   # create → fill (origin/main, now fixed) → setup → observe
```

Assert on the NEW run id:

- Gates A-E all PASS; observe shows app 200.
- `just sbx run cmd "$ID2" 'ls -la ~/.pi/agent/'` → `models.json` ABSENT —
  no stub anywhere, host or guest.
- `just sbx lifecycle execute "$ID2" "<another one-line inkwell change>" "" build-test`
  → completes 3/3, `status: success`, quality gate green, on the virgin box.
- `just sbx lifecycle teardown "$ID2"`.

## Step 8 — Close out

- `git status` clean; `git log --oneline -4` shows the spec and fix commits on
  top of `a0653cc`; `git fetch origin && git rev-parse origin/main` == HEAD.
- Envelope `changed_files`: `adws/adw_modules/agent_pi.py`,
  `adws/adw_sssf_config/sssf.meta2.config.yaml`,
  `specs/77f0e46d_models-json-optional.md`. List both run ids and their
  `.sandbox/runs/*.json` record paths as artifacts.

## Hard guards / out of scope

- The builder may modify **only** `adws/adw_modules/agent_pi.py` and
  `adws/adw_sssf_config/sssf.meta2.config.yaml` (plus committing the planner's
  spec file, per d142f7cb precedent). `git diff a0653cc HEAD --stat` must show
  exactly those three paths.
- NEVER seed `~/.pi/agent/models.json` on any box — the pass must happen with
  the file absent, or it proves nothing.
- Do NOT delete either meta roster (the roster header says "delete afterwards"
  — that is the operator's call, and deleting `sssf.meta.config.yaml` is
  beyond this run's authorization).
- No other factory path, no roster edits beyond the one authorized file, no
  Phase 2, no changes to fill.just/setup.just/provision.sh/quality.py.
- Teardown EVERY VM this run creates, green or red.
