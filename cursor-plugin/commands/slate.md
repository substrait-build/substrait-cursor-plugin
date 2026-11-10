---
name: substrait:slate
description: Create, read, change and open Substrait slates — AI-made documents, decks and interactive pages — from the editor
---

You are working with the user's **slates** on the **Substrait** platform: AI-made live
documents (`doc`), slide decks (`deck`) and interactive pages (`page`) that live in the
portal under **Slates**, are shared with colleagues, and are improved by asking the AI
again. Each slate is one self-contained HTML document per version, shown by the portal in
a sandboxed frame. This command lets the user make and change slates from here.

**A slate's page is written in one of two places. Both are supported; pick one per request.**

- **On the platform** — you send the request (`new`, `ask`) and Substrait's own AI writes
  the page in the background, on the organisation's AI key. The portal shows the page
  being written, live. Counts against the organisation's daily AI-turn cap.
- **Here, in the editor** ("local") — YOU write the HTML, with everything you can see here
  (the project's files, this conversation), and save it with the request it was written
  for (`new --from … --request`, `put … --request`). It runs on the user's own Cursor
  usage: the platform runs no model and nothing counts against the cap. The slate's
  History records the request and what changed, exactly as for a platform turn, and the
  portal shows the new version the moment it is saved (not while you write it).

**Which one:** what the user says in this request decides ("write it here", "do it
yourself", "locally", "with Cursor" → here; "on the platform", "let Substrait write it" →
platform). When they do not say, run `… mode`: it prints `platform` or `local`, the saved
default for this machine (`platform` until someone changes it). When the user states a
standing preference ("always write slates here"), save it with `… mode local` or
`… mode platform`. Never switch silently, and say in your answer which one wrote the page.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-slate.sh` under the installed `substrait` Cursor plugin) and run
`bash <plugin>/scripts/substrait-slate.sh <command>` from there. Every call needs an
**account** credential (personal access token with the Create slates permission). On a
401/403, run `/substrait:login` first — an app deploy token cannot use slates.

Work out what the user wants, then:

1. **See what exists.** `… list` prints the user's slates and the ones shared with them
   (JSON). Summarise: title, kind, version, who owns a shared one. Don't dump raw JSON.
   `… show ID` is one slate, with `url` (its portal page) and `active_turn` when the AI
   is working on it right now.

2. **Make a new one.** Pick the kind from the request (a report/proposal/memo → `doc`;
   slides → `deck`; a calculator/tracker/checklist/dashboard → `page`); if it is unclear,
   ask ONE question.
   **On the platform:** `… new --kind doc|deck|page [--title "…"] "the request"`.
   Write the request as a full brief — audience, sections or slides, tone, what must be
   in it — the AI writes the first version from it alone. Add `--wait` when the user
   wants to see the result now: the script follows the turn (typically 30–90 s) and
   prints the final version number. Tell the user the `url` so they can open it.
   **Here, in the editor:** read `… rules --kind doc|deck|page` FIRST and follow every
   rule in it (the viewer's content-security policy blocks anything else, silently). Write
   the whole page — ONE complete HTML document — to a scratch file (a temp directory, not
   the project, unless the user wants a copy kept), then
   `… new --kind doc|deck|page --from FILE [--title "…"] --request "<what the user asked,
   in their words>" --summary "<one sentence: what you wrote>"`. Tell the user the `url`.
   **From a file the user already has** (a deck exported by another tool, an HTML page
   in the project): `… new --kind doc|deck|page --from FILE [--title "…"]` makes it
   version 1 as it is — no request, no AI turn, ready at once. FILE must be ONE complete
   HTML document starting with `<!DOCTYPE html>` with everything inline or from the CDNs
   the viewer allows (as in step 4; linked local images or stylesheets will not load).
   The title is FILE's `<title>` unless `--title` says. No `--request`: nobody asked for
   this file just now. Changes come afterwards.

3. **Change one — on the platform.** `… ask ID [--wait] "what should change"`. A turn is queued behind any
   turn already running on that slate; `--wait` follows it. **With a file:**
   `… ask ID --attach FILE "insert these slides after the agenda"` sends FILE with the
   request as material for the AI — the HTML of slides to bring into a deck, notes or a
   spec to write a section from, any text. The AI renders what it says in the slate's own
   style; it is not `put` (which replaces the page with the file as it is). The AI edits in place for a
   small change and rewrites the page for a large one — either way the result is a new
   version and the old ones stay (see `… versions ID`; `… history ID` is what was asked).

4. **Change one — here, in the editor.** Always start from the page as it is NOW, never
   from a copy you fetched earlier: other people, the platform's AI and the page itself
   (a checklist ticked in the browser) all make versions.
   - `… show ID` — the `kind`, and `active_turn`: if the platform's AI is working on the
     slate right now, tell the user and wait for it (or let them decide) rather than
     racing it. `… history ID` — what was asked before; a standing instruction in it (a
     tone, an audience, a name for something) still holds.
   - `… get ID --out FILE` — writes the current page and says which version it is (N).
   - `… rules --kind <the slate's kind>` — the rules the page must keep to.
   - Make the change in FILE. Edit in place and keep everything the request does not
     touch — above all a state block (`<script type="application/json" id="state">`) that
     holds what people entered. It must stay ONE complete HTML document.
   - `… put ID FILE --base N --request "<what the user asked, in their words>" --summary
     "<one sentence: what changed>"`. A **409** means the slate moved on while you worked:
     `get` again, redo the change on the current page, `put` again with the new base —
     never overwrite, never merge blindly. Say which version landed.
   **By hand** (the user edits the file themselves, or wants a file saved as it is): the
   same `get` / `put ID FILE --base N`, with no `--request` — the version is then recorded
   as edited by hand.

5. **Open it.** `… open ID` prints the portal page's URL and opens it in the browser.

6. **The store.** A `page` may keep data in the slate's key-value store (JSON by key, up
   to 200 keys of 64 KB). `… kv ID list` shows it; `… kv ID get KEY`, `… kv ID set KEY
   '<json>'` and `… kv ID delete KEY` change it — useful to seed a tracker or inspect what
   people entered. Writing needs edit on the slate.

Things to keep straight:
- Slates are **not apps**: nothing here deploys anything. If the user wants the page to
  become a real app (a database, sign-in, an API), tell them to open the slate in the
  portal and press **Turn into an app** there.
- A `page` that keeps what people type does so by saving itself from inside the portal's
  frame; a `put` replaces the whole document, state block included — carry the current
  state block over unchanged, and warn the user before replacing a page people have been
  filling in with one written from scratch.
- `--request` is the USER's request, as they put it — not your plan, not a paraphrase that
  drops what they asked for. Colleagues read it in the slate's History, and the platform's
  AI reads it as the conversation so far the next time someone asks it for a change.
- A page written here is held to the same rules as one the platform writes: nothing
  loaded from outside the allowed CDNs, no credentials or personal data the user did not
  give you for it, and never a file from the project pasted in whole unless they asked.
- Public links, sharing and deleting are portal actions (the slate's Share panel); don't
  look for them here.
- Quote the server's reason when something is refused (a daily turn cap → 429, a slate
  the user may only view → 403); don't retry blindly.
