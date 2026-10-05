# Plan: README lane mental-model callout + hot-reload serve example

## Scope

Two surgical edits to `README.md` **only**. Every other file is out of scope. No self-commit — the chain's commit phase owns the commit; leave the tree dirty for it.

## Verified facts (checked against source of truth)

- `just/sandbox/run/mod.just` header confirms: `run cmd` = synchronous generic escape hatch for inspection; `run agent` = hand off to pi over a resumable session for steering. Neither writes the run record, neither is a phase. `run agent` invokes `pi -p --session-id $SID` — one pi turn per invocation, no chain, no gate, no commit step.
- `just/sandbox/lifecycle/execute.just` confirms: `just sbx lifecycle execute RUN_ID PROMPT CONFIG ADW` runs the full SDLC detached (default chain `sdlc`), with gates/reviews/commits to the run branch.
- `just/sandbox/manage/harvest.just` confirms: harvest pulls the run's commits home as a git bundle into `.sandbox/repos/...` refs, non-destructive.
- `just/sandbox/lifecycle/observe.just` confirms: observe starts the app once (`nohup $SERVE_COMMAND`), is idempotent (won't stack a second server), and interpolates `SERVE_COMMAND` verbatim — so `bun --hot server.ts` in the manifest works as-is.
- Mount/teardown are the only create/destroy lanes (`mount` chains create→fill→setup→observe; teardown always explicit).
- Existing README already links `[The app contract](#the-app-contract)` (in §1 "Set up a new app") — reuse that exact anchor form.

## Edit 1 — Lane mental-model callout in "## Set up a new app and develop in a sandbox"

**Placement:** immediately after the section's intro paragraph (the line `The main flow, top to bottom. Every command is a `just` recipe you could type by hand.`, ~line 205) and before `### 0. Prerequisites`.

**Format:** match the file's existing callout style — a bold-led block. Use a bold lead line `**Lane mental model.**` followed by a compact bullet list (the file already uses bold-led bullets elsewhere, e.g. the mount health-gate list and "Four ideas carry the whole system"). Content:

- `just sbx run agent` / `just sbx run cmd` are **steering and inspection** — `run agent` is ONE pi turn: no chains, no gates, no commits; its edits stay uncommitted working-tree changes in the sandbox.
- `just sbx lifecycle execute` is **the factory** — the full SDLC with gates, reviews, and commits to the run branch `sbx/<run-id>`.
- `just sbx manage harvest` is **bringing the run's commits home** (safe, non-destructive).
- `just sbx mount` / `just sbx lifecycle teardown` are **the only times a sandbox is created or destroyed** — mount fresh when you want a clean box; you never need a fresh mount just to test a change.

Then one closing sentence (same block or the line after it): the app process starts once at observe and does not hot-reload unless the app's own manifest opts in — point at the `serve:` example in [The app contract](#the-app-contract). (Note: that section sits *above* this one in the file; phrase it as a link, not "below".)

Keep it short — this is a callout, not a new subsection. Do not add a heading; do not renumber the existing `### 0..4` subsections.

## Edit 2 — hot-reload serve command in "## The app contract" sssf.app.yaml example

In the fenced yaml block at ~line 126–139, change the serve command line:

```yaml
serve:                  # optional — OBSERVE's app lane; no serve: means a library/CLI, skipped not failed
  command: bun run server.ts
  port: 4501            # the ONE port the exe.dev proxy exposes anonymously
```

to:

```yaml
serve:                  # optional — OBSERVE's app lane; no serve: means a library/CLI, skipped not failed
  command: bun --hot server.ts   # --hot = live reload during development: Bun re-imports the module graph without restarting the server
  port: 4501            # the ONE port the exe.dev proxy exposes anonymously
```

Keep the comment brief and in the file's trailing-comment style. Do not touch any other line of the yaml block, the hello-server prose below it, or the actual `hello-server` repo.

## Verification

1. `grep -n "Lane mental model" README.md` and `grep -n "bun --hot" README.md` — both hit exactly once each.
2. Re-read both edited regions to confirm tone/format match the surrounding file (bold-led callout, trailing `#` comments, existing anchor link form).
3. `git status --porcelain` shows only `README.md` modified (plus the committed spec file handled by the chain's own commit phase).
4. Done means: both edits landed in `README.md` only, tree clean after the chain's commit phase. No self-commit.
