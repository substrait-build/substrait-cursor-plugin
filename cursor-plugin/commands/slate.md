---
name: substrait:slate
description: Create, read, change and open Substrait slates — AI-made documents, decks and interactive pages — from the editor
---

You are working with the user's **slates** on the **Substrait** platform: AI-made live
documents (`doc`), slide decks (`deck`) and interactive pages (`page`) that live in the
portal under **Slates**, are shared with colleagues, and are improved by asking the AI
again. Each slate is one self-contained HTML document per version; the AI writes it in the
background and the portal shows it in a sandboxed frame. This command lets the user do the
same from here, and — the thing the portal cannot — pull a slate's HTML into the project to
edit it by hand (or with you) and push it back as the next version.

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

2. **Make a new one.** `… new --kind doc|deck|page [--title "…"] "the request"`.
   Pick the kind from the request (a report/proposal/memo → `doc`; slides → `deck`; a
   calculator/tracker/checklist/dashboard → `page`); if it is unclear, ask ONE question.
   Write the request as a full brief — audience, sections or slides, tone, what must be
   in it — the AI writes the first version from it alone. Add `--wait` when the user
   wants to see the result now: the script follows the turn (typically 30–90 s) and
   prints the final version number. Tell the user the `url` so they can open it.

3. **Change one.** `… ask ID [--wait] "what should change"`. A turn is queued behind any
   turn already running on that slate; `--wait` follows it. The AI edits in place for a
   small change and rewrites the page for a large one — either way the result is a new
   version and the old ones stay (see `… versions ID`; `… history ID` is what was asked).

4. **Edit by hand.** `… get ID --out slate.html` writes the current page (or
   `--version N` an older one) to a file. Edit it — it must stay ONE complete HTML
   document starting with `<!DOCTYPE html>`, with all CSS/JS inline or from the CDNs the
   page already uses (the viewer's content-security policy blocks everything else,
   silently). Then `… put ID slate.html` saves it as the next version on top of the head
   you fetched. A **409** means the slate moved on (someone else, or the AI, made a
   version meanwhile): run `get` again, redo the change on the current page, `put` again.
   Never merge blindly. Say which version landed.

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
  frame; a hand-edited copy pushed with `put` replaces the whole document, state block
  included — warn the user before overwriting a page people have been filling in.
- Public links, sharing and deleting are portal actions (the slate's Share panel); don't
  look for them here.
- Quote the server's reason when something is refused (a daily turn cap → 429, a slate
  the user may only view → 403); don't retry blindly.
