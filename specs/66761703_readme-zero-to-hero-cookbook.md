# Plan: README "From zero to hero" cookbook

## Scope

One file changes: `README.md`. Add a new cookbook section that walks a brand-new
user from an empty GitHub account to a harvested, torn-down sandbox run, using
their own freshly created app repo. Nothing else in the repo is touched.

## Placement and integration

- Insert a new `## From zero to hero: your first sandbox run` section
  **immediately after** `## Set up a new app and develop in a sandbox` ends and
  **before** `## Watch it run`. This keeps the reference-style section first
  and lets the cookbook sit as the narrative walkthrough of the same flow.
- Do **not** move, rename, or rewrite `## The app contract` or
  `## Set up a new app and develop in a sandbox`. The cookbook cross-links them
  (`[The app contract](#the-app-contract)`,
  `[Set up a new app and develop in a sandbox](#set-up-a-new-app-and-develop-in-a-sandbox)`)
  at the points where it would otherwise duplicate: the manifest schema and the
  private-repo token paragraph.
- One sentence at the top of the cookbook frames it: the reference sections
  above are the what/why; this is the whole loop typed once, end to end, on an
  app you create in the next five minutes.
- Do not touch the intro bullets, `## Install`, or any other section. No
  restructuring beyond the insertion.

## Tone and formatting

Match the existing README: short declarative sentences, bold for the load-bearing
claims, fenced `bash` blocks with `#` comments on the right, `yaml` fences for
file contents. Numbered `### N. <verb>` subsections, mirroring the `### 0.
Prerequisites` … `### 4. How it works` numbering style already used in
`Set up a new app and develop in a sandbox`.

## Section content (numbered steps, all copy-pasteable)

### 1. Create the app repo on GitHub

```bash
gh repo create <you>/<app> --public --clone     # or --private — see below
cd <app>
```

- One line for the private case: a `--private` repo clones inside the sandbox
  only if `APP_REPO_GIT_TOKEN` is set in the host `.env` — link to the
  **Private app repo** paragraph in
  `[Set up a new app and develop in a sandbox](#set-up-a-new-app-and-develop-in-a-sandbox)`
  instead of re-explaining it.
- Then seed the repo with the four files of the hello-server shape. Give the
  exact, verified contents (fetched from
  https://github.com/yhuangsh/hello-server.git this session — do not paraphrase):

`package.json`:
```json
{
  "name": "hello-server",
  "version": "0.1.0",
  "private": true,
  "scripts": { "start": "bun run server.ts" }
}
```

`server.ts`:
```ts
export function greet(name: string): string {
  return `hello, ${name}`;
}

if (import.meta.main) {
  const port = Number(process.env.PORT ?? 4501);
  Bun.serve({ port, fetch: () => new Response(greet("world") + "\n") });
  console.log(`hello-server on :${port}`);
}
```

`server.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import { greet } from "./server";

describe("greet", () => {
  test("greets by name", () => {
    expect(greet("sssf")).toBe("hello, sssf");
  });
});
```

`sssf.app.yaml` (at the repo root):
```yaml
runtime: bun
install:
  - bun install
build: []
serve:
  command: bun run server.ts
  port: 4501
  health_path: /
checks:
  test: [bun, test, server.test.ts]
```

- One sentence linking to `[The app contract](#the-app-contract)` for what each
  manifest key means — do not re-document the schema.
- Close with `git add -A && git commit -m "Seed app with sssf manifest" && git push`.

### 2. Write the roster

```bash
cp adws/adw_sssf_config/sssf.hello.config.yaml adws/adw_sssf_config/sssf.myapp.config.yaml
```

Show the `app:` block to edit (exactly the four keys the file carries):
```yaml
app:
  repo: https://github.com/<you>/<app>.git
  ref: main
  path: target
  manifest: sssf.app.yaml
```

Then:
```bash
echo 'SSSF_CONFIG=adws/adw_sssf_config/sssf.myapp.config.yaml' >> .env
```

Note in one line: the roster also needs its providers' API keys in `.env`
(`.env.sample` lists the allowlist); FILL fails fast naming any missing one.

### 3. Verify prerequisites

```bash
just sbx manage doctor            # five checks; must end with: sbx doctor: OK
```

Name the five checks as the recipe does (just/sandbox/manage/mod.just):
ssh exe.dev reachable, run-record helper runs, provisioner present, roster
provider keys set, adw layer resolves. One clause noting the exe.dev account
and `ssh exe.dev whoami` are covered in `## Install` — link, don't repeat.

### 4. Mount

```bash
just sbx mount my-run
```

- Explain the chain exactly as just/sandbox/mount.just does:
  create → fill → setup → observe, stopping at observe **on purpose** —
  teardown is never chained.
- What happens inside: FILL clones the factory and your app to `~/app/target`
  on the VM and opens the run branch `sbx/my-run` there; SETUP runs the
  **host-streamed provisioner** (the host checkout's
  `sandbox_mount/guest/provision.sh` piped over ssh — bun, just, and node+npm
  from their own CDNs, **pi at registry-latest**, then the manifest's
  `install:`/`build:`, **never apt**) and then the five-assertion health gate
  A–E. List A–E in one compact line each, copied from the existing
  `### 2. Mount` bullet list (git integrity / pi current / roster ping /
  non-zero cost / provider keys) — same wording, no drift.
- Reading the URLs: observe prints the two lines the recipe prints —
  `app  https://<vm>.exe.xyz/` (your app on the manifest's `serve.port`, 4501,
  the one anonymously exposed port) and `obs  https://<vm>.exe.xyz:4600/`
  (the trace UI, auth-gated to exe.dev users with VM access; opens in a browser
  already signed in to exe.dev). `mount` ends by printing the run id and the
  four next-step commands (execute / agent / harvest / destroy) — quote that
  shape so a first-timer recognizes it.

### 5. Develop

```bash
just sbx lifecycle execute my-run "add a /health endpoint that returns {\"status\":\"ok\"}"
```

- State the argument order exactly as the recipe declares it
  (`execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA`): the prompt is arg 2,
  the ADW chain is **arg 4**, so picking a chain means an empty-string
  placeholder for CONFIG:
  ```bash
  just sbx lifecycle execute my-run "add a /health endpoint" "" simple-sdlc
  ```
  (`sdlc` is the default; the chain names are `just adw` recipes.)
- It is detached: returns and records a PID, one SDLC per box at a time,
  `run.log` truncated per execute.
- Monitoring — **accuracy trap, get this right**:
  - `just sbx run cmd my-run 'tail -f run.log'` — the synchronous escape hatch.
  - The trace UI on :4600 (already running from observe).
  - The trace db lives **inside the sandbox** at
    `~/app/adws/adw_data/sssf.db`; the `just obs` recipes
    (`just obs sessions`, `just obs phases <adw_id>`, `just obs tail <adw_id>`)
    read `adws/adw_data/sssf.db` relative to the working directory, so to query
    the box's db from the host you go through the escape hatch:
    ```bash
    just sbx run cmd my-run 'just obs sessions'
    just sbx run cmd my-run 'just obs phases <adw_id>'
    ```
    Write it exactly this way. **Do NOT write `just phases <id>`** — no such
    recipe exists; the recipe is `just obs phases <adw_id>` (just/obs.just),
    and bare `just obs phases` on the host reads the host's db, not the run's.
  - One sentence repeating the existing two-handles distinction: `<run-id>`
    names the sandbox (`just sbx …`), `<adw_id>` names one factory run inside
    it (`just obs …`); cross-link to the paragraph in
    `[Set up a new app and develop in a sandbox](#set-up-a-new-app-and-develop-in-a-sandbox)`
    rather than re-deriving it.

### 6. Harvest

```bash
just sbx manage harvest my-run
```

- What it does in target mode (the roster's `app.repo` is set): bundles the
  run branch's commits off the VM and fetches them into a bare cache of your
  app repo at `.sandbox/repos/<app>.git` as `refs/sandbox/my-run`, leaving the
  bundle at `.sandbox/runs/my-run.bundle`. Give the two read commands the
  recipe itself prints:
  ```bash
  git -C .sandbox/repos/<app>.git log --oneline --graph <base>..refs/sandbox/my-run
  git -C .sandbox/repos/<app>.git diff <base>..refs/sandbox/my-run
  ```
- One line: harvest never merges and never touches a branch you own; safe to
  run any time, idempotent on re-run.

### 7. Teardown

```bash
just sbx lifecycle teardown my-run
```

- Always an explicit human decision, never chained — the reason `mount` stops
  at observe.
- Order: artifacts → harvest → destroy → close the run record. Harvest is on
  by default here too, and a harvest failure **aborts before destroy**; the
  only flag is `--no-harvest` (do not invent others).

### 8. Iterate

- Re-run work on the same box: another `just sbx lifecycle execute`, or
  re-fill to refresh code:
  ```bash
  just sbx lifecycle fill my-run            # idempotent: fetches, ff-only, never resets over run commits
  just sbx lifecycle fill my-run <sha>      # pin the FACTORY clone to a sha
  ```
- Accuracy notes for the writer: `fill RUN_ID *SHA` pins the **factory** clone
  (just/sandbox/lifecycle/fill.just); the **app** clone is pinned by the
  roster's `app.ref`, not by this argument. On a re-fill the run branch
  `sbx/my-run` is switched to, never re-created, and advanced ff-only.
- Close the cookbook with the loop in one line: edit prompt → execute → watch
  → harvest → teardown, and point back to
  `[Who commands what](#who-commands-what)` for the tiers and
  `[Watch it run](#watch-it-run)` for the observability surface.

## Verified command/reference inventory (already checked this session)

- `just sbx mount RUN_ID` — just/sandbox/mount.just; chains create→fill→setup→observe.
- `just sbx manage doctor` — just/sandbox/manage/mod.just; five checks, ends `sbx doctor: OK`.
- `just sbx lifecycle execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA` — just/sandbox/lifecycle/execute.just.
- `just sbx lifecycle fill RUN_ID *SHA` — just/sandbox/lifecycle/fill.just.
- `just sbx lifecycle teardown RUN_ID *FLAGS` (only `--no-harvest`) — just/sandbox/lifecycle/teardown.just.
- `just sbx manage harvest RUN_ID` — just/sandbox/manage/harvest.just; target-mode cache path `.sandbox/repos/<basename>.git`, ref `refs/sandbox/<run-id>`, bundle `.sandbox/runs/<run-id>.bundle`.
- `just sbx run cmd RUN_ID +CMD` / `just sbx run agent RUN_ID PROMPT` — just/sandbox/run/mod.just.
- `just obs sessions|phases ADW_ID|tail ADW_ID|procs|rosters|ui` — just/obs.just. **There is no `just phases`.**
- Roster `app:` block keys `repo/ref/path/manifest` — adws/adw_sssf_config/sssf.hello.config.yaml.
- `APP_REPO_GIT_TOKEN`, `SSSF_CONFIG` — .env.sample.
- Gates A–E wording — README `### 2. Mount` (already correct; copy it).
- Observe URL shapes and port semantics (4501 anonymous, 4600 auth-gated) — just/sandbox/lifecycle/observe.just final block.
- hello-server file contents — cloned https://github.com/yhuangsh/hello-server.git to /tmp this session and read; manifest matches the app-contract shape.

## Traps the builder must not fall into

1. `just phases <id>` does not exist — it is `just obs phases <adw_id>`, and on
   the host it reads the host db. In the cookbook, sandbox-db queries go
   through `just sbx run cmd my-run 'just obs …'`.
2. `execute` chain is arg 4; show the `""` CONFIG placeholder form.
3. Do not claim `mount` runs teardown, that harvest merges, or that any flag
   beyond `--no-harvest` exists on teardown.
4. The private-repo token story: one sentence plus a cross-link to the
   existing paragraph. Never suggest putting the token in a roster.
5. Keep `4501` described as the one anonymously exposed port and `4600` as
   auth-gated — that matches observe.just.
6. Use a concrete but generic run id (`my-run`) and app placeholder
   (`<you>/<app>`) consistently.

## Verification (builder runs these before reporting)

1. `just --list sbx` , `just --list sbx::lifecycle`, `just --list sbx::manage`,
   `just --list sbx::run`, `just --list obs` — every command named in the new
   section appears (exit status 0 and eyeball the list).
2. `grep -n "just phases" README.md` → no matches.
3. Re-read the new section side by side with the existing
   `## Set up a new app and develop in a sandbox`: no contradiction (same arg
   order, same gate list, same ports, same harvest destination).
4. `git status --porcelain` → only `README.md` modified (plus this spec file
   under `specs/`).
5. Markdown sanity: every fenced block closed, anchors used in links match the
   existing section headings.

## Out of scope

All other files, code changes, parked items. The tree-clean "done" criterion is
owned by the chain's commit phase; the builder leaves `README.md` modified.
