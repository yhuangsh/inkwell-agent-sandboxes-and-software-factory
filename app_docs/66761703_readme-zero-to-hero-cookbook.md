# README — "From zero to hero" cookbook

## What changed

A new section, **`## From zero to hero: your first sandbox run`**, was inserted
into `README.md` between **`## Set up a new app and develop in a sandbox`** and
**`## Watch it run`**. It is a numbered, copy-pasteable, eight-step walkthrough
that takes them from a brand-new GitHub account to a harvested, torn-down
sandbox run on their own app repo.

The reference sections the cookbook leans on (`The app contract`,
`Set up a new app and develop in a sandbox`) are untouched — they stay as the
*what* and *why*, and the cookbook sits as the narrative *how* that
demonstrates them once end to end. Cross-links go both ways: the cookbook points
to `#the-app-contract`, `#set-up-a-new-app-and-develop-in-a-sandbox`,
`#install`, `#who-commands-what`, and `#watch-it-run` whenever it would
otherwise duplicate or contradict those sections.

The only other file changed is the plan/spec at
`specs/66761703_readme-zero-to-hero-cookbook.md` (new file).

## Files that carry it
- `README.md` — new `## From zero to hero: your first sandbox run` section,
  lines 301–504 in the post-change file. 204 lines added, 0 removed.

## Section structure

| # | Step | Key commands / artifacts |
|---|---|---|
| 1 | Create the app repo on GitHub | `gh repo create <you>/<app> --public --clone` (or `--private` → cross-link to the **Private app repo** paragraph in `Set up a new app and develop in a sandbox`); seed with the `hello-server` shape: `package.json`, `server.ts`, `server.test.ts`, `sssf.app.yaml` (runtime / install / build / serve / checks); cross-link to `The app contract` for the manifest schema |
| 2 | Write the roster | `cp adws/adw_sssf_config/sssf.hello.config.yaml adws/adw_sssf_config/sssf.myapp.config.yaml`; edit `app:` block (`repo` / `ref` / `path` / `manifest`); set `SSSF_CONFIG` in `.env`; note that `.env.sample` lists the provider-key allowlist (FILL fails fast on missing keys) |
| 3 | Verify prerequisites | `just sbx manage doctor` — five checks; must end with `sbx doctor: OK`; cross-link to `Install` for the exe.dev account and `ssh exe.dev whoami` |
| 4 | Mount | `just sbx mount my-run` — chains **create → fill → setup → observe** and stops at `observe` on purpose (teardown is never chained). FILL clones the factory to `~/app` and your app to `~/app/target`, opening run branch `sbx/my-run`. SETUP runs the **host-streamed provisioner** (host checkout's `sandbox_mount/guest/provision.sh` piped over ssh — `bash -s`, never the VM's own copy) which bootstraps bun, just, and node+npm from their own CDNs and installs **pi at registry-latest**, then the manifest's `install:`/`build:` (**apt never**), then the five-assertion health gate A–E. OBSERVE starts the app on the manifest's `serve.port` (**4501** — the one anonymously exposed port) and the trace UI on **4600**, auth-gated to exe.dev users with VM access, then prints both URLs (`app https://<vm>.exe.xyz/`, `obs https://<vm>.exe.xyz:4600/`) and the four next-step commands |
| 5 | Develop | `just sbx lifecycle execute my-run "add a /health endpoint that returns {\"status\":\"ok\"}"`. Argument order is `execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA` — prompt is arg 2, ADW chain is arg 4; picking a chain means an empty-string `CONFIG` placeholder: `just sbx lifecycle execute my-run "add a /health endpoint" "" simple-sdlc`. Detached (returns and records a PID, one SDLC per box at a time, `run.log` truncated per execute). Monitoring: `just sbx run cmd my-run 'tail -f run.log'` (synchronous escape hatch), the trace UI on `:4600`, and the trace db **inside the sandbox** at `~/app/adws/adw_data/sssf.db`. Because the `just obs` recipes (`just obs sessions`, `just obs phases <adw_id>`, `just obs tail <adw_id>`) read `adws/adw_data/sssf.db` relative to the working directory, querying the box's db from the host goes through the escape hatch: `just sbx run cmd my-run 'just obs phases <adw_id>'`. Cross-link to `Set up a new app and develop in a sandbox` for the two-handles distinction (`<run-id>` names the sandbox; `<adw_id>` names one factory run inside it) |
| 6 | Harvest | `just sbx manage harvest my-run`. In target mode (the roster's `app.repo` is set) it bundles the run branch's commits off the VM into `.sandbox/runs/my-run.bundle` and fetches them into a bare cache of your app repo at `.sandbox/repos/<app>.git` as `refs/sandbox/my-run`. Two read commands the recipe itself prints: `git -C .sandbox/repos/<app>.git log --oneline --graph <base>..refs/sandbox/my-run` and `git -C .sandbox/repos/<app>.git diff <base>..refs/sandbox/my-run`. Never merges, never touches a branch you own; safe to re-run |
| 7 | Teardown | `just sbx lifecycle teardown my-run`. Always explicit, never chained (the reason `mount` stops at `observe`). Order: **artifacts → harvest → destroy → close the run record**; harvest failure aborts before destroy; only flag is `--no-harvest` |
| 8 | Iterate | `just sbx lifecycle fill my-run` (idempotent: fetches, ff-only, never resets over run commits) or `just sbx lifecycle fill my-run <sha>` (pin the **factory** clone to a sha — the **app** clone is pinned by the roster's `app.ref`). Re-fill switches to the run branch `sbx/my-run` and advances it ff-only, never re-creating it. Loop closes with cross-links to `Who commands what` and `Watch it run` |

## Why it matters

`Set up a new app and develop in a sandbox` is a reference section — it defines
phases, arguments, and gate semantics. A first-time reader needs a *narrative*
form of the same loop, one with concrete file contents and a placeholder
run-id (`my-run`) they can copy and substitute. The new cookbook is that
narrative form, kept in the same place in the README so the section flow stays
flat:

```
Install → Why this exists → Who commands what →
The app contract → The factory → The sandbox →
Set up a new app and develop in a sandbox →
From zero to hero: your first sandbox run →   ← new
Watch it run → The command surface → …
```

The reviewer checked every command, flag, path, manifest key, gate label, URL
shape, and `.env` variable against the actual recipes and against a fresh
clone of https://github.com/yhuangsh/hello-server.git (see
`review.md` in this context-handoff dir for the per-requirement ruling
table).

## How to use or verify it

- **Read it in place.** Open `README.md` between the headings
  `## Set up a new app and develop in a sandbox` and `## Watch it run`.
  Eight numbered subsections; each is a copy-pasteable chunk.
- **Cross-link sanity.** Every anchor used in the cookbook
  (`#the-app-contract`, `#set-up-a-new-app-and-develop-in-a-sandbox`,
  `#install`, `#who-commands-what`, `#watch-it-run`) matches an existing
  heading in the file.
- **No contradiction with `Set up a new app and develop in a sandbox`.**
  Same gate list, same `execute` arg order, same ports (4501 app / 4600
  obs), same harvest destination (`.sandbox/repos/<app>.git` / ref
  `refs/sandbox/<run-id>`).
- **Recipe sanity.** Every `just …` recipe the cookbook names exists:
  `just --list sbx`, `just --list sbx::lifecycle`, `just --list sbx::manage`,
  `just --list sbx::run`, `just --list obs`. `grep -n 'just phases' README.md`
  returns no matches — there is no `just phases` recipe (it is
  `just obs phases <adw_id>`, and only the host-side form would be wrong).
- **Spec for this change:** `specs/66761703_readme-zero-to-hero-cookbook.md`
  (plan + verification steps + per-trap guidance for the builder).