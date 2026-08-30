---
name: substrait:library
description: Browse the Substrait API Library and design an app against existing APIs
---

You are helping the user discover what data/APIs already exist on the **Substrait**
platform and — if they want — design a new app that consumes them. The **API Library**
is a design-time catalog with two kinds of entries:

- **`internal`** — company APIs registered by platform admins, each with a full
  OpenAPI spec, a base URL and `auth_notes` describing how to get access.
- **`app`** — deployed Substrait apps: an endpoint inventory (method/path/description
  plus the app's `https://<slug>.apps.substrait.build` base URL) and, for apps whose
  deploy harvested one (`has_full_spec: true`), the full OpenAPI spec.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-library.sh` under the installed `substrait` Cursor plugin) and run the
scripts from there.

Reads need an **account link** (personal access token). If a call fails with 401/403,
run `/substrait:login` and complete the account authorization first. Company APIs are
**brokered at runtime** by the platform (the app never holds their credentials), and a
builder with the data owner's **development access** can call them read-only from here
to see real responses while designing.

1. **Fetch the catalog:** run `bash <plugin>/scripts/substrait-library.sh list`
   (optional filters: `--q <term>`, `--tag <tag>`). The output is JSON — parse it and
   present a readable summary grouped by kind: internal company APIs first, then
   deployed apps. Show name, slug, description and endpoint count. Don't dump raw JSON
   at the user.

2. **Explore what's relevant.** Ask what the user wants to build (unless they already
   said), then pull details for the entries that could serve it:
   - `… substrait-library.sh show internal <slug>` or `… show app <slug>` — endpoint
     summary, base URL and (for internal entries) `auth_notes`.
   - For deep questions about an API (request/response shapes, parameters, fields):
     `… substrait-library.sh spec internal|app <slug> --out .substrait/specs/<slug>.json`
     then read/grep the file — full specs can be large, so never print one to the
     conversation wholesale. This works for any entry with `has_full_spec: true` and
     is the right way to read an app's schema — never fetch an app's public
     `/openapi.json` yourself; SSO-gated apps answer that with a Google login
     redirect, while the library serves the spec the platform harvested in-cluster.
     An app entry with `has_full_spec: false` has no readable schema (it serves no
     OpenAPI document, or hasn't redeployed since spec storage shipped) — say so and
     reason from the endpoint summaries instead, clearly flagged as inference.

3. **See what the API really returns — if the user has development access.** The spec
   is the design-time truth; the live API is the truth. Before locking field names,
   check whether the user may call the API from the editor:
   `… substrait-library.sh show internal <slug>` carries `development_access` (absent =
   never asked; `pending`; `approved` with `expires_at`; `rejected` with the owner's
   message). When approved, fetch a real sample of each endpoint the design leans on:
   `… substrait-library.sh call <slug> GET <path-from-the-spec> [--out .substrait/samples/<name>.json]`
   The body is the API's, verbatim; one status line goes to stderr. Read it to confirm
   shapes — never paste production records into code, fixtures or commit messages, and
   never try a write (development access is read-only by design; the script refuses).
   When there is no access yet, offer to ask for it and keep designing from the spec:
   `… substrait-library.sh request <slug> --reason "<what the app does with the data, read/write, how often>"`
   The data owner decides (7 / 30 / 90 days); the user gets an email either way.

4. **Design the app together.** Iterate with the user until the design is concrete:
   - which library APIs it consumes, and which specific endpoints;
   - data flow: what the app stores in its own database vs fetches live;
   - configuration: **company (`internal`) APIs are brokered** — the app calls them at
     `$SUBSTRAIT_EGRESS_URL/<entry-slug>/…` with `$SUBSTRAIT_EGRESS_TOKEN`, both injected
     by the platform once the data owner approves the *app*, so **never design an env
     var to hold that API's key, secret or base URL**. Other Substrait apps (`app`
     entries) are still called directly at their base URL, in a custom env var. The app's
     own secrets belong in `backend/.env.example` with a `# secret` marker, never in code.
     Note the two grants are separate: the user's development access (step 3) does not
     give the app access — that is requested on the app's **Access** tab after deploy.
   - what the app itself exposes (its own API + frontend).

5. **Build and ship.** When the user is happy with the design, use the `substrait-app`
   skill to scaffold and implement it (the design maps onto the standard backend +
   frontend + migrations layout), then `/substrait:link` and `/substrait:deploy`.
