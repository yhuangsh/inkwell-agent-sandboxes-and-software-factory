# COMMIT-LANE v1 — no-self-commit rule as a prompt-pipeline invariant

## Goal

Move the no-self-commit rule out of per-run prompt text and into the prompt
pipeline itself, so every agent prompt carries it **by construction**:

1. A single-sourced `COMMIT_LANE_RULE` block in `adws/adw_modules/prompts.py`,
   anchored by the HTML-comment marker `<!-- COMMIT-LANE v1 -->`.
2. `prompts.render()` injects the block into every rendered prompt — no call
   site can omit it.
3. `agents.validate()` asserts the builder agent's prompt *files* carry the
   marker; a missing marker is a named `ValidationError` raised before any
   agent spawns (tamper guard — injection alone would silently paper over a
   stripped file).
4. The shipped builder prompt files carry the human-readable block so the
   file check passes.

## Authorized write scope (this run's roster)

- `adws/adw_modules/prompts.py`
- `adws/adw_modules/agents.py`
- `adws/adw_data/prompt_engineering/`
- `adws/adw_sssf_config/sssf.meta5.config.yaml` (no change expected — see §5)

Do NOT touch any other roster, `data_types.py`, `permissions.py`, or the
parked ref-guard/rollback-index/deleted_files items.

## Current state (recon facts)

- `adws/adw_modules/prompts.py` is tiny: `render(template_path, variables)`
  does `Path.read_text()` + `{{key}}` replacement, and `save()` writes audit
  copies. **`render()` is the single funnel** — its only callers are
  `agents.py` lines 89–90 (`system_text = prompts.render(...)`,
  `user_text = prompts.render(...)` in `execute()`).
- `agents.validate(cfg, required)` collects problems per required agent and
  raises `SystemExit("config validation failed:\n- ...")`. There is no
  existing `ValidationError` in the codebase — it must be defined.
- Every ADW entry point (`adw_build.py`, `adw_plan_build.py`, …) calls
  `agents.validate(cfg, REQUIRED_AGENTS)` before any phase runs, so a raise
  inside `validate()` fires before any agent spawns. The builder agent is
  named `"builder"` in every roster.
- Both the default roster (`sssf.config.yaml`) and this run's roster
  (`sssf.meta5.config.yaml`) point builder at
  `adws/adw_data/prompt_engineering/builder/{system,user}.md` — one edit
  covers both.
- `prompt_engineering/` holds `builder/`, `planner/`, `scout/`, `reviewer/`,
  `documenter/`, each with `system.md` + `user.md`.
- ADW scripts import via `from adw_modules import ...` with `adws/` on
  `sys.path`; there is no `adws/__init__.py`. Verification snippets must
  `sys.path.insert(0, "adws")` first.
- Tree currently has one untracked file: `adws/adw_sssf_config/sssf.meta5.config.yaml`
  (this run's roster, created by the orchestrator). Leave it; the chain's
  commit phase will pick it up.

## Changes

### 1. `adws/adw_modules/prompts.py` — the rule, single-sourced

Add two module-level constants:

```python
COMMIT_LANE_MARKER = "<!-- COMMIT-LANE v1 -->"

COMMIT_LANE_RULE = """
<!-- COMMIT-LANE v1 -->
## Commit lane — no self-commit

You are FORBIDDEN from every git ref mutation: commit, push (including
--delete), tag, branch create/delete/switch, checkout, switch, reset,
rebase, merge — INCLUDING `git checkout -- <path>` and any other
file-discarding form of checkout/restore.

Allowed git: `git add`, and read-only commands — status, diff, log, show,
rev-parse, branch --show-current / --list / -a, remote get-url.

The chain's kind="code" commit phases own every commit. Leave your work
dirty in the tree; do not try to "help" by committing it.

Your report's changed_files lists only files that exist afterwards;
deletions go in summary / notes_for_next_agent.
""".strip()
```

Refine wording freely; keep the semantics exactly: forbidden = every ref
mutation + `git checkout -- <path>` discards; allowed = `git add` +
read-only git; the chain commits; leave the tree dirty; changed_files =
existing files only, deletions in prose.

**Injection inside `render()`** (this is the "no call site can omit it"
requirement — render is the only funnel):

```python
def render(template_path, variables):
    text = Path(template_path).read_text()
    for key, value in variables.items():
        text = text.replace("{{" + key + "}}", value)
    if COMMIT_LANE_MARKER not in text:          # idempotent: files that already
        text = text.rstrip() + "\n\n" + COMMIT_LANE_RULE + "\n"   # carry the block pass through
    return text
```

Idempotency matters: the builder's own prompt files will carry the block
(§4), so without the marker check the block would appear twice. Leave
`save()` untouched — it writes whatever `execute()` already rendered, so the
audit copies automatically show the injected block.

### 2. `adws/adw_modules/agents.py` — validate() marker assertion

Define a named error near `GateFailure`:

```python
class ValidationError(Exception):
    """Config failed semantic validation (e.g. a prompt file lost its
    COMMIT-LANE v1 marker). Raised before any agent spawns."""
```

In `validate()`, inside the per-agent loop (after `resolve`), add: when
`agent.name == "builder"`, for each of `agent.prompt_engineering.system` /
`.user`, **if `Path(ref).is_file()`**, assert the file's text contains
`prompts.COMMIT_LANE_MARKER`; on absence raise:

```python
raise ValidationError(
    f"agent 'builder': {label} prompt {ref} is missing the "
    f"{prompts.COMMIT_LANE_MARKER} marker — the commit-lane rule must be "
    f"present in the builder's prompt files, not only injected at render time")
```

Notes:
- Raise `ValidationError` directly (do not funnel it into the `problems`
  list / `SystemExit`) so the tamper test can catch it by name.
- Do the marker check **before** the `agent_pi.resolve_model(...)` call in
  the loop body, so the tamper test does not depend on host model
  resolution succeeding.
- Exemption: if the ref is not a file, skip the marker check for it
  (render injection still covers that agent at runtime). Genuinely missing
  files keep the existing "prompt not found" behavior.
- Only the agent named `"builder"` gets the file check; other agents rely
  on render injection alone.

### 3. `adws/adw_data/prompt_engineering/builder/system.md` and `user.md`

Append the human-readable block — the exact text of `COMMIT_LANE_RULE`
including the `<!-- COMMIT-LANE v1 -->` marker line — to the end of both
files. Keep it identical to the constant so file and injection never
disagree (copy the text once the constant is written).

Other agents' prompt files: optional, at your discretion. Recommendation:
leave them unmarked — verification (b) then doubles as proof that injection,
not file content, is what covers them.

### 4. `adws/adw_sssf_config/sssf.meta5.config.yaml`

No change required. It already authorizes exactly this scope. (Its header
says "Delete when landed" — that is a later run's call, not this one's.)

## Verification (host-side, from repo root)

Use `uv run --with pydantic --with pyyaml python -` (or the project's
usual runner) with `sys.path.insert(0, "adws")`. All three must exit 0.

**(a) Builder render carries the marker (default roster):**

```python
import sys; sys.path.insert(0, "adws")
from adw_modules import agents, prompts
cfg = agents.load_config()                      # default: sssf.config.yaml
b = agents.resolve(cfg, "builder")
v = {"prompt": "x", "previous_envelope": "(none)", "context_handoff_dir": "/tmp/ch"}
for ref in (b.prompt_engineering.system, b.prompt_engineering.user):
    out = prompts.render(ref, v)
    assert prompts.COMMIT_LANE_MARKER in out, ref
    assert out.count(prompts.COMMIT_LANE_MARKER) == 1, "block duplicated — idempotency broken"
print("OK builder")
```

**(b) Injection covers every agent (scout + reviewer, files unmarked):**

```python
for name in ("scout", "reviewer"):
    a = agents.resolve(cfg, name)
    for ref in (a.prompt_engineering.system, a.prompt_engineering.user):
        assert prompts.COMMIT_LANE_MARKER in prompts.render(ref, v), ref
print("OK scout/reviewer")
```

**(c) Tamper test — marker-less builder files fail validate() by name (temp
files only, NEVER the tracked ones):**

```python
import tempfile, pathlib
from adw_modules.data_types import AgentConfig, PromptEngineering, SSSFConfig
tmp = pathlib.Path(tempfile.mkdtemp())
sysmd = tmp / "system.md"; usrmd = tmp / "user.md"
sysmd.write_text("# Builder\n\nNo commit-lane rule here.\n")
usrmd.write_text("# Build Task\n\n{{prompt}}\n")
rogue = AgentConfig(name="builder",
                    prompt_engineering=PromptEngineering(system=str(sysmd), user=str(usrmd)))
cfg2 = SSSFConfig(agents=[rogue])
try:
    agents.validate(cfg2, ["builder"])
except agents.ValidationError as e:
    assert "COMMIT-LANE v1" in str(e)
    print("OK tamper:", e)
else:
    raise SystemExit("FAIL: validate() did not raise ValidationError")
```

If `SSSFConfig` has required fields beyond `agents`, mirror them from the
loaded default config (`cfg.model_dump()` minus agents) instead of
constructing bare.

Also run a quick import smoke check: `uv run adws/adw_build.py --help` or
equivalent exits 0 (the modules still import cleanly).

## Standing rules for this run

- NO git ref mutations: no commit, push, checkout, branch, reset, rebase,
  merge, tag — including `git checkout -- <path>`. `git add` is allowed;
  read-only git is allowed. The chain's kind="code" commit phase owns the
  commit.
- Leave the tree dirty.
- `changed_files` lists only files that exist afterwards (expect:
  `adws/adw_modules/prompts.py`, `adws/adw_modules/agents.py`,
  `adws/adw_data/prompt_engineering/builder/system.md`,
  `adws/adw_data/prompt_engineering/builder/user.md`; the untracked
  `sssf.meta5.config.yaml` is the orchestrator's, not yours — do not list
  it unless you changed it).
- Scratch output to `/tmp`, never into the repo.

## Done means

All three verifications (a)(b)(c) green, modules import cleanly, no git ref
mutation performed, tree left dirty for the chain's commit phase.
