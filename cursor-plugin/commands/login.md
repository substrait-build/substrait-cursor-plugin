---
name: substrait:login
description: Authenticate this machine with your Substrait account (mints the personal access token), or switch between saved logins
---

You are authenticating the user's machine with the **Substrait** platform: a one-time
**account authorization** that mints a **personal access token** (`sbt_…`). It is
machine-wide — every project on this machine can then browse the API Library
(`/substrait:library`), bind itself to an app (`/substrait:link`), and deploy
(`/substrait:deploy`) without any per-project secret.

Each login is saved as a **profile** — one Substrait installation (portal URL) as one org —
in `~/.substrait/profiles/<name>.json`; the **active** profile is copied to
`~/.substrait/config.json`. A person who works on two installations (say the hosted
platform and a demo or self-hosted one), or in two orgs of one installation, keeps one
profile per login and switches between them; a login to a different installation or org
never touches another profile, and a login under an existing profile's name **replaces**
it (the token it replaces is revoked when a login minted it — a hand-minted one is kept
and said so). A project linked under a profile stays **pinned** to it, so switching the
active profile never retargets an existing folder's deploys.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there.

**The Substrait portal/API URL is REQUIRED — there is no default.** Establish it first:
- If the user supplied a URL as the command argument (`$ARGUMENTS`), use that.
- If `$ARGUMENTS` is the name of a saved profile instead (see step 0), the user wants to
  **switch** to it — skip to step 5.
- Otherwise **ask the user for their Substrait portal/API URL** and wait for it — do NOT
  guess or assume a hosted default. It's the API base, e.g. `https://api.substrait.build`
  for the hosted platform, or a tenant/demo/self-hosted install's own URL such as
  `https://api.demo.substrait.build`. The portal's own "connect" instructions show the
  exact URL for that environment.
Pass it as `--portal-url <URL>` on the authorization command below. (Once stored, later
commands read it from the profile — the URL is only needed here at login.)

0. **See what is saved:** run `bash <plugin>/scripts/substrait-link.sh profiles`.
   One line per profile: `name`, portal, org, email, and `active` / `pinned` (pinned = the
   current folder was linked under it). Exit 1 and a note when there are none yet.

1. **Check whether the machine is already authenticated:** run
   `bash <plugin>/scripts/substrait-link.sh whoami`.
   This verifies the active profile's token against its portal and prints who it
   authenticates, in which org, under which profile. If it succeeds and the user wanted
   that installation and org, tell them they're already logged in (as whom, where) and
   stop. Continue when they want to re-authenticate, log in to **another** installation
   or org (a new profile — nothing already saved is touched), or switch accounts.

2. **Browser authorization (preferred):**
   `bash <plugin>/scripts/substrait-link.sh account --portal-url <URL> [--profile <NAME>] [--org <SLUG>]`
   This opens the Substrait portal in the user's browser, where they (already logged in
   there) **authorize Cursor on their account** — the personal token is minted and
   returned to the CLI automatically, no copy/paste. The command prints a URL and a short
   verification code; relay both to the user in case the browser didn't open, and tell
   them to complete the authorization in the browser. It blocks until they approve.
   - `--portal-url` is **required** (the URL from the preamble) — the command errors
     without it (except when re-authenticating a saved `--profile`, whose portal is reused).
   - `--org <slug>` pins the profile to one org of that installation. Only needed when the
     user belongs to several orgs there and wants one other than their default; the
     script refuses an org they are not a member of and lists the ones they are in.
     `bash <plugin>/scripts/substrait-link.sh orgs` lists the active login's orgs
     (`slug`, name, `active`).
   - `--profile <name>` names the profile; the default is the portal's host
     (`api.substrait.build`), or `<org>@<host>` when `--org` was given. Letters, digits,
     `.`, `_`, `-`, `@`. The new profile becomes the active one.

3. **Headless / CI fallback.** If there is no browser on this machine: the user mints a
   personal token on the portal's **Personal tokens** page (account menu), then
   `bash <plugin>/scripts/substrait-link.sh save-account --token <TOKEN> --portal-url <URL> [--profile <NAME>] [--org <SLUG>]`
   (`--portal-url` **required**). Ask **only for the token**; never echo it back in plain
   text. The script verifies it before saving. (In CI, `SUBSTRAIT_PROFILE=<name>` in the
   environment forces a saved profile for every command, and `SUBSTRAIT_PORTAL_URL` /
   `SUBSTRAIT_TOKEN` / `SUBSTRAIT_ORG` override the files entirely.)

4. **Confirm** with a `whoami` and tell the user what's now unlocked: `/substrait:link`
   to bind a project to an app, `/substrait:library` to browse the API catalog,
   `/substrait:deploy` to ship. This command does **not** bind the current project to
   any app — that's `/substrait:link`.

5. **Switching between saved logins** is `/substrait:switch` (it lists the profiles and
   asks which). When the user named one here, do the same thing directly:
   `bash <plugin>/scripts/substrait-link.sh use-profile <NAME> [--project]`
   Makes `<NAME>` the active profile: what `/substrait:link` lists apps from and binds
   under, and what unpinned folders use. A folder already linked under another profile
   keeps deploying there (the script says so); pass `--project` only when the user wants
   **this** folder moved to the other login as well — it re-verifies the bound app slug
   under the new profile. Report the line the script prints (profile, portal, org).

To sign out of one login — revoking the token on the portal, not just deleting the local
file — use `/substrait:logout` (`--profile <NAME>` for one that is not active).
