---
name: substrait:link
description: Link this project to a Substrait app (account link — pick or create the app right here)
---

You are linking the current working directory to one app on the **Substrait** platform so
the user can deploy it with `/substrait:deploy`. Two credential models exist:

- **Account link (preferred):** a **personal access token** (`sbt_…`) stored once per
  machine as a **profile** (one Substrait installation as one org; the active one is in
  `~/.substrait/config.json`, see `/substrait:login`). It authenticates the user; each
  project then just records **which app** it deploys to (a slug in
  `.substrait/config.json`, no secret) and **which profile** it was linked under, so the
  folder keeps deploying to that installation and org whatever profile is active later.
- **Per-app deploy token** (`sbd_…`, the original flow): scoped to a single app, stored in
  the project. Still fully supported — and it wins over the account token if both exist.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts from
there. They self-locate their shared helper, so they only need to be invoked by path.
**Always prefix script invocations with `SUBSTRAIT_MEMO_FILE=AGENTS.md`** — the scripts
maintain a project-memory block and Cursor reads `AGENTS.md`, not the default `CLAUDE.md`.

**If any authentication has to be established below (account link or per-app token), the
Substrait portal/API URL is REQUIRED — there is no default.** If the user supplied a URL
as the command argument (`$ARGUMENTS`), use it; otherwise **ask the user for their
Substrait portal/API URL** (e.g. `https://api.substrait.build` hosted, or a tenant/demo
URL like `https://api.demo.substrait.build` — the portal's connect page shows it) and pass
it as `--portal-url <URL>`. It's only needed when first writing auth to config; if the
machine/project is already linked, skip straight to binding.

1. **Check current state:** run `bash <plugin>/scripts/substrait-link.sh status`.
   It reports both layers: whether this machine has an account link (which profile, portal
   and org), and what this project is bound to. If the project is already linked and the
   user only wanted to check, you're done. If it says the folder is pinned to a profile
   that is **not on this machine**, the user either signs in to it (`/substrait:login`,
   `account --profile <that name> --portal-url <URL>`) or re-links under another — don't
   deploy around it. If the machine has several profiles, the **active** one is what the
   steps below list apps from and bind under: confirm with the user that it is the
   installation and org they mean (`bash <plugin>/scripts/substrait-link.sh profiles`;
   switch with `bash <plugin>/scripts/substrait-link.sh use-profile <NAME>`).

2. **Ensure the account link (once per machine).** If status says there's no account link
   (also available standalone as `/substrait:login`, which also covers a second
   installation or org — `--profile` / `--org`):
   `bash <plugin>/scripts/substrait-link.sh account --portal-url <URL>`
   This opens the Substrait portal in the user's browser, where they (already logged in)
   **authorize Cursor on their account** — the personal token is minted and returned to
   the CLI automatically, no copy/paste. The command prints a URL and a short verification
   code; relay both to the user in case the browser didn't open, and tell them to complete
   the authorization in the browser. It blocks until they approve.
   - `--portal-url` is **required** (the URL from the preamble); the command errors without it.
   - Headless / CI fallback: the user mints a token on the portal's **Personal tokens**
     page (account menu), then `bash <plugin>/scripts/substrait-link.sh save-account --token <TOKEN> --portal-url <URL>`
     (`--portal-url` required). Ask **only for the token**; never echo it back in plain text.

3. **Bind this project to an app.** With the account link in place:
   - List the user's apps: `bash <plugin>/scripts/substrait-link.sh apps`
     (prints `slug<TAB>display name` lines). Show them to the user and ask which app this
     project should deploy to — or whether to create a new one. **Mode awareness:** `apps`
     prints a note on stderr when the workspace's per-tenant toggles constrain creation —
     either "GitHub only" (a new app needs a repo, see below) or creation disabled
     entirely (then offer only existing apps and relay the note).
   - Existing app: `bash <plugin>/scripts/substrait-link.sh use --app <SLUG>`
   - New app:      `bash <plugin>/scripts/substrait-link.sh create --name "<NAME>"` —
     refused with the reason when the workspace disallows it (or the app quota is full);
     relay that message verbatim, don't retry.
   - New app in a **GitHub-only workspace** (zip uploads switched off):
     `bash <plugin>/scripts/substrait-link.sh create --name "<NAME>" --repo <owner/repo>
     [--branch <BR>]` — the app is created already connected to that repo and records
     `deploy_mode: connect`. `bash <plugin>/scripts/substrait-link.sh repos` lists the
     repos the Substrait GitHub App can reach (empty ⇒ the user installs the App on the
     repo first, via the URL it prints). The code must live in that repo: offer
     `git init` / `gh repo create` / push help when it doesn't yet. A bare `create` here
     fails with exactly this guidance — retry it with `--repo`, don't loop.

4. **Per-app token fallback.** If the user prefers a token scoped to one app (shared
   machines, CI secrets):
   - Browser flow: `bash <plugin>/scripts/substrait-link.sh login --portal-url <URL>` (pick
     the app in the browser; the `sbd_…` token is fetched automatically). `--portal-url`
     is **required**.
   - Paste flow: mint on the app's **Deploy** tab, then
     `bash <plugin>/scripts/substrait-link.sh save --token <TOKEN> --portal-url <URL>`
     (`--portal-url` required).

5. **Confirm** the linked app + preview URL (and the profile it was linked under, which
   the script names), and remind the user they can now run `/substrait:deploy` to ship
   the current code.

Related: how the app *deploys* (zip upload vs GitHub trigger) is a separate, switchable
choice — `bash <plugin>/scripts/substrait-link.sh modes` shows the current state and
`bash <plugin>/scripts/substrait-link.sh set-mode --mode upload|connect [--repo <owner/repo>]`
switches it (offered automatically during `/substrait:deploy`; GitHub is only offered
where the workspace has Connect to GitHub enabled).

Note: on a successful link, the script also records a **"Substrait deployment" section
in the project's `AGENTS.md`** (creating the file if needed; that's why the
`SUBSTRAIT_MEMO_FILE=AGENTS.md` prefix matters) so every future session knows the deploy
contract without loading the skill. It's a marker-delimited block the plugin keeps
current on later deploys; deleting the whole block opts the project out — don't re-add
it by hand if the user removed it.
