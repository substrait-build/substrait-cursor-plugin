---
name: substrait:deploy
description: Deploy the current project to its linked Substrait app (zip upload, or a pushed-branch trigger for GitHub-connected apps)
---

You are deploying the current project to **Substrait**. This plugin bundles a deploy
script that picks the path from the linked app's mode: a **GitHub-connected app** is
deployed by *trigger* — Substrait pulls the pushed branch, so nothing is uploaded and
everything (including `openapi.json` and `substrait.yaml`) must be **committed and
pushed** first — while any other app is zipped (source only) and uploaded. Either way,
`--watch` follows the build until the preview is live.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-deploy.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there. They self-locate their shared helper, so they only need to be invoked by path.
**Always prefix script invocations with `SUBSTRAIT_MEMO_FILE=AGENTS.md`** — the scripts
maintain a project-memory block and Cursor reads `AGENTS.md`, not the default `CLAUDE.md`.

1. **Check the link:** run `bash <plugin>/scripts/substrait-link.sh status`.
   If this project isn't linked, stop and tell the user to run `/substrait:link` first.
   Deploys are authorised either by the machine's account link (personal token + this
   project's bound app slug) or by an app-scoped deploy token saved in the project —
   linking sets up whichever the user chose.

1b. **Offer the deploy-path choice (once).** Run
   `bash <plugin>/scripts/substrait-link.sh modes` — it prints `app_mode` (the app's
   current path), `tenant_upload`/`tenant_connect` (what this workspace allows) and
   `chosen` (the recorded choice in `.substrait/config.json`).
   - If `chosen` is set, or the app is already connected (`app_mode: connect`), just
     proceed — the choice is made. To change it later the user runs
     `bash <plugin>/scripts/substrait-link.sh set-mode`.
   - Otherwise, if `tenant_connect: enabled`, ask the user once: deploy this app by
     **zip upload** (simplest — ships the working tree) or **connect it to a GitHub
     repo** (deploys build the pushed branch; sha-verified)?
     - GitHub: walk the one-time setup in order — `modes` also prints the local git
       state (`git_repo`, `git_branch`, `git_remote`) so you know which steps apply:
       1. **No git repo yet** (`git_repo: no`)? Offer to initialize it:
          `git init -b main`, then `git add -A && git commit -m "Initial commit"`.
          (`.substrait/` is already gitignored by the link step — keep it that way.)
       2. **The `gh` CLI makes the rest one-command** (optional — the browser path
          below works without it). Check `command -v gh`:
          - Not installed? Offer to install it with the platform's package manager
            (`brew install gh` on macOS, `winget install --id GitHub.CLI` on Windows,
            the distro package or GitHub's official apt/dnf repo on Linux) — with the
            user's go-ahead, run the install yourself and verify with `gh --version`.
          - Installed but not logged in? Check `gh auth status`; if it reports no
            authentication, have the **user** run `gh auth login` in a terminal —
            it's interactive (browser device-code flow), so don't run it yourself
            and wait for it. Re-check `gh auth status` after.
       3. **Pick the GitHub repo:** `bash <plugin>/scripts/substrait-link.sh repos`
          lists the repos reachable through the user's Substrait GitHub App
          installations (rows: `repo<TAB>default branch<TAB>install id`). If the repo
          they want isn't listed — or doesn't exist on GitHub yet — help them create
          it: with `gh` authenticated,
          `gh repo create <owner>/<name> --private --source=. --push` creates the
          repo, adds `origin` and pushes in one go; without `gh` they create it in
          the browser. Then have them install the Substrait GitHub App on it (relay
          the install URL `repos` prints when empty; existing installations are
          extended from GitHub's app settings page) and re-run `repos` until the
          repo appears.
       4. **No `origin` remote** (`git_remote: none`)? Add it and push:
          `git remote add origin <the repo's SSH or HTTPS URL>` then
          `git push -u origin <branch>`. If the push fails on authentication, go back
          to the `gh auth login` step (or their SSH key) — never guess or embed
          credentials.
       5. **Connect:** `bash <plugin>/scripts/substrait-link.sh set-mode --mode connect --repo <owner/repo> --branch <the branch you pushed>`.
     - Zip: `bash <plugin>/scripts/substrait-link.sh set-mode --mode upload` (records
       the choice).
   - If `tenant_connect: disabled`, don't offer GitHub — proceed with the zip path.
   - A `set-mode` refusal (403 prose — the workspace disallows that mode) is relayed
     verbatim, never retried. Mode switching needs the account link; app-scoped
     deploy tokens can't do it (the script says so).

2. **Author the app's OpenAPI spec** — write **`openapi.json` at the project root**
   (next to `backend/` and `substrait.yaml` — commit it, it's part of the code): a
   complete OpenAPI 3.x document you author by studying the backend source. It ships
   inside the deploy and the platform records it as the app's published API
   description — it takes precedence over the platform's runtime harvest, and it's
   what other builders see in the platform's **API Library** (portal **API** tab
   included). Your spec is usually *richer* than the runtime one — frameworks only
   emit response schemas for typed handlers, but you can read what each handler
   actually returns.

   What to write:
   - **Every route the code registers** — method + path (route params in `{param}`
     form), including `/health`. Nothing invented, nothing padded: if it isn't in the
     code, it isn't in the spec.
   - **A real `summary` per operation** — one sentence saying what the endpoint does
     (not a restatement of its path).
   - **Request bodies and parameters** — from the handler signatures/models.
   - **Response schemas** — trace each handler's return value (dict literals, ORM
     rows, serializers) and write the actual field names and types under
     `responses.200.content.application/json.schema`. Share shapes via
     `components/schemas`. Where a field's type is genuinely unknowable from the code,
     leave that field generic rather than guessing — accuracy beats completeness.

   Keep it valid JSON with a top-level `paths` object, under 1 MB. Regenerate the file
   whenever the backend's routes or shapes change — each deploy replaces the whole
   spec, so removed endpoints drop out. If you genuinely cannot read the backend
   (e.g. it's a compiled artifact), skip this step — the platform falls back to
   harvesting the running app's own `/openapi.json` when it serves one. (Legacy: an
   inventory-only `.substrait/endpoints.json` is still accepted when no spec file
   exists.)

   **Also keep the app's description current** — `substrait.yaml` at the project root
   is **required**, with a top-level `description:` (1–3 sentences: what the app does,
   the data it manages, who it's for). Each deploy records it onto the app, and it's
   what teammates see in the portal and the platform's **API Library** — so write it
   from what the app *actually does now*, and update it when the app's purpose grows.
   A missing file, a missing description, or leftover scaffold placeholder text fails
   the deploy's validation (the script pre-checks this locally). Create the file with
   just the `description:` key if the app declares no backing services — but if the
   app already uses redis/kafka/qdrant, keep them declared under `services:`.

3. **Get the branch deploy-ready if the app is GitHub-connected: offer to commit and
   push.** A connected app's deploy builds the **pushed branch**, not the working
   tree — so before running the deploy script, check the local git state
   (`git status --porcelain`; compare HEAD against the pushed tip of the connected
   branch). If anything is uncommitted or unpushed, don't just report it — **offer to
   handle it**: summarize what would ship, propose a short commit message, and with
   the user's go-ahead run `git add -A && git commit -m "<message>" && git push`.
   Never commit or push silently, with one exception: the deploy script stamps
   `scaffold_version` into `substrait.yaml` during preflight (it prints "Stamped
   scaffold_version …") — when a run refuses for uncommitted changes right after
   that stamp, commit and push the stamp (and only the stamp, unless the user already
   agreed to more) and re-run without asking; it's mechanical. If the user declines
   the offer, explain the deploy will build the currently pushed tip without their
   local changes, and let them decide whether to proceed.
   The script refuses to trigger from a dirty tree, the wrong branch, or an unpushed
   HEAD, and the server independently verifies the commit SHA — if it reports a
   mismatch, push (or pull a teammate's newer commits) and re-run. Do not try to work
   around these gates; they exist so the platform never builds code the user didn't
   explicitly ship. (Zip-deployed apps skip this step — the zip carries the working
   tree directly.)

4. **Deploy** from the project root:
   `bash <plugin>/scripts/substrait-deploy.sh --watch`
   The script runs a **compliance preflight** before deploying anything — it halts if
   the repo isn't Substrait-compliant (missing backend Dockerfile, a
   `frontend/` with no frontend Dockerfile, a stray `k8s/`, or a missing/placeholder
   `substrait.yaml` description). If it reports a
   compliance failure, relay the exact message and help the user fix the repo; do not
   try to bypass it.
   For zip deploys the script also auto-detects the **backend stack**
   (fastapi/python/node/go/rust/…) from
   the project and records it on the app as a label — the platform is stack-agnostic, so
   this only affects what's shown in the portal. If the guess is wrong, pass
   `--stack <name>` (e.g. `--watch --stack go`). Connected apps ignore `--stack` — the
   platform detects the stack from the repo itself.
   If the script warns that the **spec is stale** (`openapi.json` older than backend
   changes), stop and regenerate it from the current backend source before deploying —
   the file ships with the deploy and becomes the app's published API description, so
   a stale one publishes wrong schemas.

5. **Report the outcome:** the run number and, on success, the live preview URL. If the
   script reports a failure, surface the HTTP status / message and suggest checking the
   portal logs for that run — do not retry automatically.

Note: for zip deploys the script enforces the 16 MB source-only limit and excludes
`node_modules/`, `.venv/`, `dist/`, build output and `.git/`. If it reports the zip is
too large, help the user find and exclude the offending large files rather than
bypassing the check.

## Deploy environments

An app can have more than one **deploy environment** — `production` (the app's own
instance) plus e.g. `staging` or `dev`, each with its own namespace, database, URL
(`<slug>--<env>.<org>.apps.substrait.build`), variables and access settings. Environments
are created on the app's page in the portal (the environment switcher under the header).

- `--env <name>` deploys to that environment instead of production:
  `bash "${CURSOR_PLUGIN_ROOT}/scripts/substrait-deploy.sh" --env staging --watch`
- The script refuses a name the app does not have; production needs no flag.
- The same folder deploys to any environment — nothing in the code changes. The app can
  read `SUBSTRAIT_ENV` (`production` | `preview`), `SUBSTRAIT_ENV_NAME` and `APP_URL`
  at runtime.
- A non-production environment's database is seeded from `backend/db/seed.sql` when the
  file exists (applied on the first deploy, again only when the file changes, and again on
  the first deploy after a database reset).
  Production is never seeded.
- **Promote** one environment's live build into another — the way staging reaches
  production without a rebuild:
  `bash "${CURSOR_PLUGIN_ROOT}/scripts/substrait-deploy.sh" promote --to production --from staging --watch`
  `--from` defaults to the `--env` / pinned environment (else production). The target's
  database is migrated from that build's tree first, then its images are copied into
  the target's own repositories and rolled out. The target must have been deployed at
  least once. A protected target (production by default) accepts this from the app
  owner or an admin only — a collaborator gets a 403 with that explanation.
- To pin a folder to an environment for every command, add `"environment": "staging"` to
  `.substrait/config.json`; `$SUBSTRAIT_ENV_TARGET` works too. `--env` always wins.
