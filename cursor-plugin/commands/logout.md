---
name: substrait:logout
description: Sign this machine out of your Substrait account (revokes the personal access token and removes the local link)
---

You are signing the user's machine out of the **Substrait** platform — the counterpart of
`/substrait:login`. Two things can be removed, and they are separate:

- **One login (always):** the personal access token (`sbt_…`) of the **active profile**
  (`~/.substrait/config.json` + its `~/.substrait/profiles/<name>.json`), or of the
  profile named with `--profile <NAME>`. Other saved profiles are untouched — the script
  lists what remains and how to activate one. Signing out of the active profile affects
  every project on this machine that is not pinned to another profile.
- **This project's binding (only with `--project`):** `.substrait/config.json`, i.e. which
  app the current folder deploys to, plus any app-scoped deploy token (`sbd_…`) stored in
  it.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin) and run the scripts from
there. They self-locate their shared helper, so they only need to be invoked by path.
**Always prefix script invocations with `SUBSTRAIT_MEMO_FILE=AGENTS.md`** — the scripts
maintain a project-memory block and Cursor reads `AGENTS.md`, not the default `CLAUDE.md`.

**Revocation is the point, and it is not undoable.** A token minted by `/substrait:login`
is revoked on the portal, not merely deleted locally — otherwise a live credential would
outlive the logout. The user cannot un-revoke it; they simply log in again to mint a new
one. A token the user minted themselves on the portal and pasted in (`save-account`) is
**kept** by default, because it may be in use on another machine or in CI; the script says
so and offers `--revoke`.

1. **Show what is about to go**, so this isn't a blind destructive action:
   `bash <plugin>/scripts/substrait-link.sh status` and, when more than one login may be
   saved, `bash <plugin>/scripts/substrait-link.sh profiles`.
   They report the active profile (portal, org) plus this project's binding and pin. If
   there is no account link, say so and stop unless the user also wants `--project`.

2. **Confirm with the user** before running the logout — name the profile/account/portal
   from step 1, and state plainly that the token will be revoked on the portal. Also ask
   whether to unbind this project (`--project`) if they haven't said. Skip the
   confirmation only if the user's request already made both answers explicit.

3. **Run it:**
   `bash <plugin>/scripts/substrait-link.sh logout [--profile <NAME>] [--project] [--revoke|--keep-token]`
   - `--profile <NAME>` — sign out of that saved login instead of the active one. The
     active profile stays active.
   - `--project` — also unlink the current folder. Do this when the user is handing the
     machine over, or wants the folder to stop pointing at that app. The app itself, its
     deployments and its data are untouched: unlinking is a local operation (plus revoking
     that one deploy token).
   - `--revoke` — also revoke a hand-minted token the script would otherwise keep. Only
     pass this when the user has said they want the token dead everywhere.
   - `--keep-token` — leave the credential valid on the portal and only remove the local
     file. For a shared or CI-provisioned token the user still needs elsewhere.
   The script always removes the local files, even when the portal is unreachable — it
   then tells the user the token is still live and where to revoke it.

4. **Report** exactly what happened, relaying the script's own lines: whether the token was
   revoked or deliberately kept (and why), whether the project was unbound, and that
   `/substrait:login` re-authenticates when they come back. Anything the script printed as
   a `note:` is worth surfacing verbatim — those are the cases where a credential is still
   alive somewhere.

Note: the **"Substrait deployment" block in `AGENTS.md`** is deliberately left in place —
it documents the deploy contract for future sessions and is not a credential. Delete it by
hand if the user wants the project to forget Substrait entirely.
