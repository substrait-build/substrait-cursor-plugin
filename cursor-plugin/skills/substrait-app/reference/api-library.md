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
  full OpenAPI spec. These appear automatically once an app deploys.

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

Note the catalogue is **scoped by the org's data groups**: orgs can restrict
sensitive operations (endpoint + method) to members who hold the covering group,
and operations you don't hold are simply absent — lists omit them, counts shrink,
served specs drop them, and an entry whose whole inventory is grouped away answers
404 on `show`/`spec`, exactly like a slug that never existed. If the user names an
API or endpoint you cannot see, say the library doesn't list it for this account
and suggest they check with their org admin — don't retry or treat it as an outage.

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
