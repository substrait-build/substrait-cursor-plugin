# Substrait plugin for Cursor

Build apps to the Substrait upload/deploy contract and ship them without leaving the
editor. The plugin bundles:

- the **`substrait-app`** skill — scaffolds a contract-compliant app (FastAPI `backend/`
  on port 8000, `cicd/` Dockerfiles, optional React+Vite+Tailwind `frontend/`, Flyway
  migrations); and
- seven commands:
  - **`/substrait:login`** — authenticate this machine with your Substrait account (mints
    the personal access token; one browser authorization, no copy/paste). Each login is a
    saved **profile** — one installation as one org — so you can hold several.
  - **`/substrait:switch`** — pick which saved login the machine acts under: lists your
    profiles and activates the one you choose (a linked folder keeps its own login unless
    you move it).
  - **`/substrait:logout`** — sign out of one login again: revokes the login-minted token on
    the portal and drops the stored credential (`--profile` picks a saved login,
    `--project` also unbinds this folder).
  - **`/substrait:link`** — link this project to one of your apps. Opens the portal in your
    browser so you pick the app while logged in; the app-scoped deploy token is fetched
    automatically (no copy/paste). Falls back to pasting a token for headless/CI.
  - **`/substrait:deploy`** — package the project (source only) and deploy it to the linked
    app (`--watch` to follow the build).
  - **`/substrait:env`** — view and set the linked app's environment variables and secrets
    (secrets are write-only; changes live-apply to a running app).
  - **`/substrait:library`** — browse the platform's API Library and design an app against
    existing APIs.
  - **`/substrait:slate`** — create, change, pull and push back **slates** (AI-made
    documents, decks and interactive pages): ask for one from a brief, ask it to change,
    fetch its HTML to edit by hand, save it back as the next version, open it.

## Install

In Cursor, add the marketplace and install the plugin:

```
substrait-build/substrait-cursor-plugin
```

(Cursor → Plugins/Marketplace → add the `substrait-build/substrait-cursor-plugin` repo → install
the `substrait` plugin.)

## Set up & deploy

1. In your project, run `/substrait:link`. It opens the portal in your browser (you're
   already logged in), where you **pick the app** to link — the deploy token is minted for
   that app and returned to the CLI automatically. The app must already exist.
2. Run `/substrait:deploy` to ship (add `--watch` to follow the build to the live URL).

**Headless / CI?** If there's no browser, mint a token by hand: portal → your app → its
**Deploy** tab → **Create deploy token**, copy the `sbd_…` value (shown once), then run
`/substrait:link` and paste it.

Config is **per project** in `./.substrait/config.json` (chmod 600, gitignored) — the app
slug and the login profile it was linked under (or, with a per-app token, portal URL + the
app-scoped token). Logins are **profiles** in `~/.substrait/profiles/<name>.json`, one per
installation-and-org; `~/.substrait/config.json` is the active one. You can override with
`SUBSTRAIT_PORTAL_URL` / `SUBSTRAIT_TOKEN` / `SUBSTRAIT_ORG` in the environment, or force a
saved profile with `SUBSTRAIT_PROFILE=<name>` (handy in CI).

**Several installations or orgs?** Log in to each (`/substrait:login`, with `--org <slug>`
for an org other than your default — the profile is named after the portal's host, or
`<org>@<host>`), then switch with `/substrait:switch`. A folder linked under one
profile keeps deploying there whichever profile is active; `/substrait:logout --profile
<name>` signs out of just that one.

**Portal URL.** Substrait is multi-tenant, so there is no default — the URL is always
explicit. Supply it once with `/substrait:login --portal-url <URL>` and every later command
reads it from the profile.

## Maintainers

**This repository is published, not edited here.** It is generated from canonical sources
in the Substrait monorepo and pushed by `scripts/publish-cursor.sh`:

- `skills/substrait-app/` is assembled from `portal-backend/app/resources/` by
  `scripts/sync-cursor.sh` (the same sources the portal, agent-runner, and the Claude Code
  plugin build from).
- `scripts/substrait-{common,link,deploy}.sh` are the editor-agnostic bash scripts copied
  verbatim from the Claude Code plugin (`substrait-plugin/scripts/`) by the same sync.
- the Cursor-specific glue (`.cursor-plugin/plugin.json`, `commands/`, `hooks/hooks.json`,
  `scripts/substrait-update-check-cursor.sh`) is authored in the monorepo under
  `cursor-plugin/`.

To ship a change, edit the sources in the monorepo, run `bash scripts/sync-cursor.sh`, then
`bash scripts/publish-cursor.sh`. Direct commits here will be overwritten on the next
publish.

## License

MIT — see [LICENSE](LICENSE).
