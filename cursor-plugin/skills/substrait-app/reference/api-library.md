# The API Library — designing apps against existing APIs

The Substrait portal serves a catalog of APIs an app can be built against — and, for
company APIs, brokers the credentials to call them. It has two kinds of entries:

- **`internal`** — company APIs registered by platform admins. Each entry carries a
  name, slug, description, tags, a base URL, `auth_notes` (how the API authenticates and
  who owns it — documentation, never credentials) and a full **OpenAPI spec**. Apps call
  these **through the platform gateway**, never directly; see *Calling a library API*.
- **`app`** — deployed Substrait apps: an endpoint inventory (method/path/description
  for every route the app serves), its `https://<slug>.apps.substrait.build` base URL,
  and — when the post-deploy harvest captured one (`has_full_spec: true`) — the app's
  full OpenAPI spec. An app's entry exists once it deploys, but its endpoints
  are **published only through data groups** — see *Browsing it* below.

## Browsing it

The `/substrait:library` command wraps the plugin's `substrait-library.sh`:

```
substrait-library.sh list [--q TERM] [--tag TAG]     # the whole catalog (JSON)
substrait-library.sh show internal|app SLUG          # one entry + endpoint summary
substrait-library.sh spec [internal|app] SLUG [--out FILE]  # an entry's full OpenAPI doc
```

Under the hood these call the portal API (`GET /api/library`,
`GET /api/library/{internal|apps}/{slug}`, `GET /api/library/{internal|apps}/{slug}/spec`),
authenticated with the **account** personal access token (`sbt_…`) — an app-scoped
deploy token cannot browse the library. Prefer the endpoint summaries; pull a full
spec to a file (`--out`) only when you need request/response detail, and grep it
rather than printing it. For app entries, `spec app SLUG` serves the doc the platform
harvested from the running app — use it instead of fetching the app's public
`/openapi.json`, which is gated behind Google SSO for SSO-enabled apps.

Note the catalogue is **published through the org's data groups**: an operation
(endpoint + method) is visible only to members who hold a group that names it, and
an operation in **no group is hidden from everyone** except platform admins — for
company APIs and deployed apps alike, deploying or registering publishes nothing by
itself. Operations you don't hold are simply absent — lists omit them, counts shrink,
served specs drop them, and an entry whose whole inventory is hidden answers 404 on
`show`/`spec`, exactly like a slug that never existed. If the user names an API or
endpoint you cannot see — or the catalog comes back empty in an org that has deployed
apps — say the library doesn't list it for this account and suggest an org admin add
the operations to a data group the account holds; don't retry or treat it as an
outage. An API that is not in the library AT ALL can be proposed: the portal's app
Access tab has a "Request an import" form (name + spec URL + reason), and a library
curator decides — approval registers it, still unpublished until grouped.

## Calling a library API

The two kinds of entry are called in **two different ways**, and getting them the wrong
way round is the mistake to avoid.

### `internal` entries — brokered through the platform gateway

Company APIs are never called with a credential the app holds. The app calls the
platform's egress gateway, and the gateway attaches the real credential on its behalf:

```
GET $SUBSTRAIT_EGRESS_URL/<entry-slug>/<the API's own path>
Authorization: Bearer $SUBSTRAIT_EGRESS_TOKEN
```

Both variables are injected by the platform. **Do not declare them in
`backend/.env.example`** — they are reserved, and a declaration is *silently ignored*
rather than refused: the deploy succeeds and the variable simply never appears, which
is a much harder thing to debug than an error would be.

So, when you design against an internal entry:

- **Never design an env var to hold that API's key, token, client secret, or base URL.**
  There is nothing for the user to paste. If you find yourself writing
  `ORDERS_API_KEY=  # secret`, you have designed the pre-brokering shape by mistake.
- Build the URL from `$SUBSTRAIT_EGRESS_URL` plus the entry slug plus the path from the
  spec. The entry's own `base_url` is documentation — the gateway holds the real one.
- `auth_notes` describes how the API authenticates and who owns it. It is context for
  the design conversation, not instructions for the app to follow.

**Access must be granted before any call works.** The app needs an approved grant for
that entry, and until then every call is refused with a message saying so. The user
requests it on the app's **Access** tab in the portal (or you can raise it for them),
and the API's data owner approves. Tell the user this is needed — an app that builds
fine and then 403s at the gateway looks like a bug when it is really a pending approval.

A refusal from the gateway is plain text and says which of these it is: an unrecognised
token, no approved grant, or no upstream credential configured. Surface it rather than
retrying.

### Seeing real responses while you build — development access

The spec says what an endpoint returns; the API says what it *actually* returns, and
the two differ often enough that building blind is how integrations ship with the wrong
field names. So a **person** — not an app — can be granted **development access** by
the same data owner, and then call the API from the editor through the platform:

```
substrait-library.sh access                       # your development access, every state
substrait-library.sh request <slug> --reason "…" [--group ID]  # ask the data owner (≥10 chars)
substrait-library.sh call <slug> GET /2.0/shippers?limit=1
substrait-library.sh call <slug> GET /2.0/shippers/2 --out .substrait/samples/shipper.json
```

**Grants ride on data groups.** A request is anchored on the API you name, but what
the owner approves is a **data group** — approval covers every operation that group
names, this API's and any other it covers alike. Usually the group resolves
automatically (your account holds exactly one group covering the API); if several
cover it the request answers 409 listing them with ids — re-run with `--group <id>`.
The same applies to an app's access request on its portal Access tab.

`call` prints the response body on stdout exactly as the API sent it, and one status
line on stderr (`GET /2.0/shippers?limit=1 → HTTP 200 · 412 ms · application/json ·
6595 bytes`). Read it the way you would read the spec — to learn the real shape — and
prefer `--out` plus grep for anything large. The platform attaches the credential;
you never see it, and every call is recorded against your account.

What development access is, so you set expectations correctly:

- **Read-only.** `GET`, `HEAD` and `OPTIONS` only. A write is refused before it leaves
  the platform, whatever the grant says. Do not try to work around this; if the design
  needs a write verified, that is a conversation with the data owner, not a call.
- **Time-boxed.** The owner grants 30 or 60 days (30 by default) — every data
  authorisation carries this clock, an app's grant included. When it lapses,
  `call` says so and `request` asks again.
- **Scoped like the spec.** You can only call operations your account can *see* —
  the same data-group rule that shapes `show` and `spec`. An operation that is not in
  the spec, or is hidden from you, answers 404 either way.
- **Production data.** These are the real base URLs. Treat what comes back as you
  would treat production records — use it to learn shapes, never paste it into code,
  fixtures or commit messages.

Ask for it early — the owner is a person and may take a day — and keep designing from
the spec in the meantime. `show internal <slug>` carries `development_access` with
your current state (`pending`, `approved` with `expires_at`, `rejected` with the
owner's message), so you do not need a failed call to find out.

### `app` entries — called directly

Another Substrait app's API is **not** brokered. Call it directly at its
`https://<slug>.apps.substrait.build` base URL, which belongs in a custom env var in
`backend/.env.example` as it always did. Note it may sit behind that app's Google SSO
proxy — check with the app's owner whether a service path exists before designing
against it.

## Designing an app from the library

1. `list` the catalog and shortlist entries relevant to what the user wants to build.
2. `show` the shortlisted entries; read `auth_notes` and the endpoint summaries.
3. Agree the design with the user: endpoints consumed, what the app stores in its own
   per-app database vs fetches live, and the app's own API/frontend surface. Env vars
   only for `app` entries' base URLs — internal APIs need none, because the gateway
   holds their credentials.
4. Scaffold and implement per this skill's deploy contract, then link and deploy.
5. For each internal API consumed, make sure access is requested and approved — the
   app deploys happily without it and then gets refused at the gateway, so raise it
   as part of shipping rather than leaving the user to discover it.
