---
name: substrait:switch
description: Switch between your saved Substrait logins (installations and orgs) — lists the profiles and activates the one you pick
---

You are switching which saved **Substrait login** this machine acts under. Each login is
a **profile** — one Substrait installation (portal URL) as one org, saved by
`/substrait:login` in `~/.substrait/profiles/<name>.json`; the **active** profile is what
`/substrait:link` lists apps from and binds new folders under, and what unpinned folders
use. A folder that is already linked stays **pinned** to the profile it was linked under —
switching never retargets its deploys unless the user moves the folder on purpose (step 4).

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts from
there. **Always prefix script invocations with `SUBSTRAIT_MEMO_FILE=AGENTS.md`** — moving a
folder (step 4) refreshes the project-memory block, and Cursor reads `AGENTS.md`, not the
default `CLAUDE.md`.

Never print a token. The script never shows one either; relay its lines as they are.

1. **List the saved logins:** run `bash <plugin>/scripts/substrait-link.sh profiles`.
   One tab-separated row per profile: `name`, portal, org (`-` if none), email, and a
   marks column — `active`, `pinned` (this folder was linked under it), `active,pinned`,
   or `-`. A `note:` on stderr means this folder is pinned to a profile that is not on
   this machine; surface it.
   - Exit 1 / no rows: there are no saved logins — tell the user `/substrait:login`
     creates one, and stop.
   - Exactly one row: say it is the only login and already active, and stop (unless the
     folder is pinned elsewhere — then go to step 4).

2. **Pick one.** If the user named a profile as the command argument (`$ARGUMENTS`,
   matched exactly against the `name` column), use it. Otherwise show the rows as a
   numbered table (name · portal · org · email · marks, with the active one marked) and
   **ask the user which one to switch to** — wait for the answer; never guess. If they
   pick the one already active, say so and stop (or go to step 4 if the folder is pinned
   to a different one).

3. **Switch:** `bash <plugin>/scripts/substrait-link.sh use-profile <NAME>`
   Relay its `Active profile: '<name>' (<portal>, org '<org>')` line. From now on
   `/substrait:link`, `/substrait:library` and every unpinned folder act under it.

4. **This folder.** If the script adds "This project stays pinned to '<other>' — its
   deploys are unaffected", the current folder is linked under a different login. Tell the
   user that plainly, and **ask** whether they want this folder moved to the login they
   just chose. Only on a clear yes:
   `SUBSTRAIT_MEMO_FILE=AGENTS.md bash <plugin>/scripts/substrait-link.sh use-profile <NAME> --project`
   It re-verifies that the folder's app exists under the new login and keeps the folder's
   deploy mode and environment pin; if the app is not there it says so and the folder's
   previous binding is left exactly as it was — relay that, don't retry. If the folder is
   not linked at all, mention that `/substrait:link` now binds it under the new profile.

5. **Confirm** with `bash <plugin>/scripts/substrait-link.sh whoami` and report who the
   machine is now authenticated as, on which portal, in which org.

Related: `/substrait:login` adds a login (`--org <slug>` for a second org of the same
installation, `--profile <name>` to name it); `/substrait:logout --profile <name>` removes
one.
