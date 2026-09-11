# Substrait deploy contract — full reference

You upload **app code plus its Dockerfile(s)**. Your app builds from its **own**
Dockerfile, so the contract is behavioural and **stack-agnostic** — a container that
`EXPOSE`s 8000 and serves `GET /health`, in any language or framework — not locked to
FastAPI. The platform owns **only the Kubernetes
manifests**: it mints the slug and binds namespace, image and ingress host, so you never
write k8s or deal with the slug. The k8s manifests are never committed into your repo;
they're materialised at deploy time. The worker:

1. **VALIDATING** — extracts the zip (zip-slip safe) and validates your app against this
   contract (a backend Dockerfile is required; a frontend one too when you ship `frontend/`).
2. **REPO_INIT** — creates a private GitHub repo and pushes your code as-is, one
   commit per deploy (your Dockerfiles included; no k8s manifests added).
3. **BUILDING → MIGRATING → DEPLOYING → SMOKE_TEST → PREVIEW_LIVE** — the platform's
   warm builder (BuildKit) builds **your** Dockerfile straight from the repo; Flyway
   runs your migrations; then the platform renders its k8s manifests (slug + image
   bound) and applies them.

## What goes in the zip

| Path | Required | Notes |
|------|----------|-------|
| `cicd/Dockerfile.backend` (or `cicd/Dockerfile` / `backend/Dockerfile`) | ✅ | builds the backend image; must `EXPOSE 8000`, serve `GET /health` and the API under **`/api`** |
| `cicd/Dockerfile.frontend` (or `frontend/Dockerfile`) | ✅ when `frontend/` present | builds the SPA image; serves the built bundle on **port 80** |
| `cicd/nginx.conf` | with the scaffold's frontend Dockerfile | serves the SPA; referenced by `Dockerfile.frontend` |
| `backend/main.py` | scaffold | the scaffold's Dockerfile runs `uvicorn main:app` on port 8000; serves `GET /health` and its API under **`/api`** |
| `backend/requirements.txt` | scaffold | your backend deps (installed by your Dockerfile) |
| `backend/.env.example` (or root `.env.example`) | optional | declares custom env vars + secrets; the platform pre-creates them in the app's Settings. Mark secrets with a trailing `# secret` |
| `backend/resources/db/migration/V*.sql` (or `resources/db/migration`) | optional | Flyway, MySQL/OceanBase dialect |
| `frontend/` | optional | any framework that serves on port 80 (scaffold: React + Vite + Tailwind); **deployed** alongside the backend (see Full-stack below) |

**Do not** include `k8s/` — anything you put there is discarded and replaced by the
platform's manifests. You **do** ship the `cicd/` Dockerfiles; the platform no longer
generates one.

## You own the Dockerfile; the platform owns only k8s (no `__APP_SLUG__` to manage)

The platform generates the k8s manifests from internal templates, fills in the slug it
mints from your display name, and binds the app to its namespace, image and ingress
host. **You write none of that and never reference the slug.** Your Dockerfile, by
contrast, is yours — start from the scaffold's `cicd/Dockerfile.backend` and edit it
freely, as long as the image still `EXPOSE`s 8000 and serves `GET /health`.

### The backend runs capless — stock nginx won't start there

The backend container runs with **all Linux capabilities dropped**. A capless process
(uvicorn, a Go binary, etc.) is fine. **Stock `nginx` is not**: its entrypoint chowns
`/var/cache/nginx` at startup, which needs `CAP_CHOWN`, so it dies with
`nginx: [emerg] chown("/var/cache/nginx/...") Operation not permitted` and crashloops.
If your backend is a static server, build it `FROM nginxinc/nginx-unprivileged` (runs
rootless with no startup chown — keep `listen 8000`), or move the static content to a
`frontend/` slot, which grants nginx the capabilities it needs. The deploy is rejected up
front with this fix if a backend Dockerfile is `FROM nginx`.

### The frontend's nginx must not proxy to a compose hostname

`/api` is routed to the backend by the ingress and never reaches the frontend container,
so its nginx config needs no `proxy_pass` at all (the scaffold's `cicd/nginx.conf` is
static-only). Adding a compose-style `location /api/ { proxy_pass http://backend:8000; }`
for local development is fatal on the platform: nginx resolves every literal
`proxy_pass`/`upstream server` hostname when it loads its config, `backend` does not exist
in the app's namespace, and nginx refuses to start — the frontend crash-loops with
`host not found in upstream "backend"` and the app 502s. The deploy is rejected at
VALIDATING when a file the frontend Dockerfile copies under `/etc/nginx/` names a dot-less
host that is not the app's own Service (`<deploy-slug>-backend[-direct]`,
`<deploy-slug>-frontend[-direct]`), its database pod, or a declared backing service
(`redis`/`kafka`/`qdrant`). FQDNs, IPs and `$variable` targets are not checked. For
compose, use `npm run dev` (Vite proxies `/api`) or a separate compose-only nginx config
that the Dockerfile never copies.

### Wheels-only by default (Python scaffold only)

This is a convenience of the **Python/FastAPI scaffold**, not a contract rule — ignore it
if your backend uses another stack. The scaffold's `cicd/Dockerfile.backend` installs deps
with `pip install --only-binary=:all:`. The base is `python:3.12-slim`, which has no C
compiler, so a dep with no wheel for this Python would otherwise fall back to a source
build and die deep in a cryptic compile (surfaced as a `BackoffLimitExceeded` build
failure). `--only-binary` makes that fail fast and legibly instead. If you genuinely
need a source build, pin a version that ships a wheel, or add the toolchain
(`apt-get install -y gcc …`) and drop the flag.

### Build context depends on where the Dockerfile lives

- `cicd/Dockerfile.backend` / `cicd/Dockerfile` is built with the **repo root** as the
  context, so its `COPY` paths are repo-root-relative: `COPY backend/requirements.txt .`,
  `COPY backend/ .` (this is what the scaffold ships).
- `backend/Dockerfile` is built with **`backend/` as the context** — write it like a
  standalone service Dockerfile: `COPY requirements.txt .`, `COPY . .`.

If a `COPY`/`ADD` source can't be found in that context, the deploy is rejected up front
with a clear message rather than failing deep inside the image build.

## Build resource ceiling (heavy deps)

Images are built on the platform's shared BuildKit builders, whose cache disk is
sized for ordinary app images (a few GB installed footprint each). There is no hard
per-build quota, but a single image whose layers run to tens of GB will fail with
`no space left on device` and starves every other build's cache — keep images lean.

The usual culprit is **GPU PyTorch**: `torch` (often pulled transitively by
`sentence-transformers` / `transformers`) defaults to the CUDA build, dragging in
~6 GB of `nvidia-*` wheels that don't fit — and the cluster has no GPUs anyway. Pin the
**CPU-only** build instead, e.g. in your `backend/Dockerfile`:

```dockerfile
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir -r requirements.txt
```

(or add `--extra-index-url https://download.pytorch.org/whl/cpu` and pin `torch==X.Y.Z+cpu`).

## Full-stack: one host, path-based routing

The app deploys into one sandbox namespace behind **one ingress host**:

- **`/api`** → the backend service.
- **everything else** → the frontend (the SPA) **when you ship a `frontend/`**;
  otherwise it also goes to the **backend** (see backend-only below).

So the backend **must serve its HTTP API under `/api`** (e.g. `/api/users`), and the
frontend calls the API **same-origin via relative `/api` paths** — no API URL is baked
into the bundle (the scaffold's `cicd/Dockerfile.frontend` builds with `VITE_API_URL=""`).
That Dockerfile builds the Vite bundle and serves it via nginx on port 80; the platform
deploys `<slug>-frontend` beside `<slug>-backend`.

**Backend-only (no `frontend/`).** You need no frontend Dockerfile, and the platform
routes **all** traffic — `/api` *and* everything else, including `/` — to the backend.
This means a backend-only app **must serve its own root and pages itself**, not just
`/api`: a single container that renders the whole site (e.g. a Next.js or server-rendered
app) works as-is, but a pure-API backend with no `/` route will return its own **404** on
the homepage (not a 502 — the app is reachable; it just hasn't defined a root route).

### Build-time frontend env vars (`frontend/.env.production`)

Vite inlines `import.meta.env.VITE_*` at **build time**, but the portal's env vars
(`.env.example` → app Settings) are injected into the **backend at runtime only** — they
never reach the Vite build. So a `VITE_GOOGLE_CLIENT_ID` set in the portal will be
`undefined` in the shipped bundle. To set build-time frontend vars, commit a
**`frontend/.env.production`** file: your `cicd/Dockerfile.frontend` runs
`npm run build` in production mode, so Vite auto-loads it and inlines the values.

```
# frontend/.env.production — build-time, PUBLIC-ONLY values
VITE_GOOGLE_CLIENT_ID=1234567890-abc.apps.googleusercontent.com
VITE_SENTRY_DSN=https://abc@o0.ingest.sentry.io/0
```

> ⚠️ **PUBLIC values only — never secrets.** Unlike `backend/.env.example` (whose values
> you fill in privately in the portal and are injected at backend runtime), everything in
> `frontend/.env.production` is **committed to git AND baked into the shipped JS bundle**,
> which any visitor can read. Put only non-secret, publishable config here (OAuth *client*
> IDs, public DSNs, analytics keys, feature flags). API keys, client *secrets*, tokens →
> `backend/.env.example`, proxied through your backend.

- **Leave `VITE_API_URL` unset — use relative `/api` paths.** The scaffold's
  `cicd/Dockerfile.frontend` sets `ENV VITE_API_URL=""` before `npm run build`, and that
  process env beats `.env` files, so any `VITE_API_URL` you put in `.env.production` is
  **silently ignored**. Keep it that way so the SPA hits the backend same-origin via the ingress.
- **`.gitignore` gotcha:** most real Vite projects ship a `.gitignore` containing `.env`
  or `.env*`, which would silently drop this file so it never reaches the build. If your
  `.gitignore` ignores env files, explicitly un-ignore this one:
  ```gitignore
  .env*
  !.env.production
  ```
  (The Substrait scaffold's `frontend/.gitignore` already keeps `.env.production` tracked.)
- Changing a value here requires a **re-upload / rebuild** (it's compiled into the bundle).
  This is the right home for config that changes rarely; for values you want to rotate
  without a rebuild, fetch them at runtime from a backend endpoint instead.

## Runtime contract

- Backend is **any language or framework** — you own the Dockerfile, so the contract is
  purely behavioural (the scaffold happens to use FastAPI). Meet the points below and you're done.
- Listen on **port 8000**; serve **`GET /health`** (200, the readiness probe) and your
  API under **`/api`** (so the ingress routes it to the backend).
- Database is **declared explicitly** in `substrait.yaml` — without a `database:` key
  there is **no database and no `DATABASE_URL`**, and shipping Flyway migrations
  anyway fails VALIDATING. Three engines:
  - `oceanbase` — a database on the platform's shared, multi-zone HA cluster (MySQL
    wire protocol). Nightly backups; the portal's Database tab (browse / migrate /
    repair / reset) works. **The default; use it unless you need otherwise.**
  - `postgres` / `mysql` — the app's **own single-node pod** (10Gi disk) in its
    namespace, reachable at `postgres:5432` / `mysql:3306`. Real engine semantics, at
    dev/internal-tool grade: one replica, **no HA, no platform backups, no Database-tab
    tooling**. Deploys still run Flyway normally.

  The engine is **fixed once deployed** — there is no cross-engine data migration, so
  changing the value fails the deploy instead of handing the app an empty database of
  the other kind. Removing the declaration never deletes a provisioned DB (or its
  disk); data is dropped only with the app itself.
- Read secrets from env (injected via the `app-secrets` Secret):
  - `DATABASE_URL` (only when `database:` is declared) — scheme follows the engine.
    `oceanbase`/`mysql` → `mysql://user:pass@host:port/db`: use a **MySQL** driver,
    never PostgreSQL (`asyncpg`/`$1`); Python (scaffold): `asyncmy` + `%s`
    placeholders. `postgres` → `postgresql://user:pass@postgres:5432/app`: use a
    Postgres driver (`asyncpg`/`psycopg`) with `$1`-style placeholders. Go/other
    stacks: convert the URL to your driver's DSN — see *Connecting from Go & other
    stacks* below.
  - `JWT_SECRET`
  - Backing-service connection strings, present **only for services declared in
    `substrait.yaml`** (see *Backing services* below): `REDIS_URL`, `KAFKA_BROKERS`,
    `QDRANT_URL`, `OBJECT_STORAGE_BUCKET`.
- Declare your app's **own** config (API keys, flags, third-party creds) in
  `backend/.env.example`: one `NAME=value` per line, a trailing `# secret` to mark a
  secret. On upload the platform pre-creates these under the app's Settings (prefilled
  with the example value) for the user to fill in. Don't list the platform-injected
  keys above; read your vars at runtime via `os.getenv`. Re-uploading only adds new
  keys — it never overwrites values already set in the portal.
- All DDL in Flyway migrations — never in application code.
- **API description** (optional): ship an `openapi.json` at the repo root (valid JSON,
  top-level `paths`, ≤ 1 MB) and the platform records it at deploy as the app's
  published API description — shown on the portal's API tab and in the API Library,
  taking precedence over the runtime harvest of the app's own `/openapi.json`. Author
  it from the code; never list endpoints or fields the code doesn't serve.
- **App manifest (REQUIRED)**: every app ships a `substrait.yaml` at the repo root
  with a top-level `description:` — 1–3 sentences on what the app does and who it's
  for (≤ 2000 chars). Each deploy records it onto the app; the portal and the API
  Library show it. A missing manifest, a missing description, or the scaffold's
  untouched placeholder fails VALIDATING with the fix in the message. The manifest
  also carries the app's `database:` declaration (above) and its backing services
  (below).
- **Backing services** (optional): declare in the same `substrait.yaml` and the
  platform provisions them in the app's namespace, injecting the connection env var.
  Installing a client library does nothing by itself — the manifest is the only
  trigger, and a service the app already uses MUST stay declared (omitting it removes
  the service on the next deploy).

  ```yaml
  description: >
    Tracks team leave requests with an approvals workflow, for people managers.
  database: oceanbase      # or postgres | mysql; omit if the app uses no database
  services:
    redis: {}              # → REDIS_URL=redis://redis:6379/0
    kafka:                 # → KAFKA_BROKERS=kafka:9092 (single-node Redpanda, Kafka-compatible)
      persistent: true
    qdrant: {}             # → QDRANT_URL=http://qdrant:6333 (gRPC on qdrant:6334)
    object-storage: {}     # → OBJECT_STORAGE_BUCKET=<private GCS bucket, one per environment>
  ```

  The catalog is exactly those four; `persistent` (default `false`) is the only option and
  applies only to the three **pod** services — anything else fails validation at upload with
  the fix in the message. Ephemeral pod services
  lose their data on pod restart (treat redis as a cache; recreate qdrant collections if
  missing at startup). `persistent: true` adds a disk that survives restarts and redeploys
  (fixed sizes — redis 1Gi, kafka 10Gi, qdrant 5Gi). Removing a pod service from the manifest
  — or deleting the whole file — removes it on the next deploy (the disk is kept;
  re-declaring re-adopts it). The kafka
  broker trades strict fsync durability for footprint — use it for events and jobs, not as
  a system of record. Pod services are reachable only from inside the app's own namespace.

  **`object-storage` is not a pod** — it is a private cloud bucket belonging to the app, and
  it behaves differently on every axis above: it takes no options, holds durable data rather
  than cache, is reached over the network with a GCS client rather than at a namespace
  hostname, and needs **no credential** — the pod authenticates as itself, so nothing about
  it belongs in `.env.example`. That same identity lets the app mint **time-limited URLs**
  for browser-direct download and upload, so large files need not stream through the pod —
  again with no key or secret involved. Removing the declaration does **not** delete the
  bucket or stop `OBJECT_STORAGE_BUCKET` being injected; the deploy just warns. The bucket
  is deleted only after the whole app is deleted, and after a grace period. See
  `reference/object-storage.md`.
- Source only in the zip: exclude `node_modules/`, `.venv/`, `dist/`,
  `__pycache__/`, build output. Max size 16 MB (default).
- Frontend (optional) is **any framework** that builds to a site served on **port 80** —
  the scaffold uses React + Vite + Tailwind (see `reference/templates/frontend/`), but Vue,
  Svelte, Astro, plain static HTML, etc. all work. Ship a `cicd/Dockerfile.frontend` that
  serves it on port 80 (the scaffold uses nginx + `cicd/nginx.conf`). Call the API with
  relative `/api` paths.
- Build-time frontend config (`VITE_*`) goes in a committed **`frontend/.env.production`**
  (public, non-secret values only — it's baked into the JS bundle). Leave `VITE_API_URL`
  unset (the frontend Dockerfile forces `""`). See *Build-time frontend env vars* above.

### User identity under Google SSO (optional)

If the app owner enables **Google single sign-on** (the portal's Access tab), every
request that reaches your backend has already passed the platform's auth proxy, and the
proxy **injects the signed-in user's identity as request headers**:

| Header | Value |
|---|---|
| `X-Forwarded-Email` | the Google account email (the useful one — key user data on this) |
| `X-Forwarded-User` | the provider's opaque user ID |
| `X-Forwarded-Preferred-Username` | display username, when Google provides one |

So an app that needs to know *who* is using it needs **no OAuth flow, no login page, no
session handling of its own** — read the header:

```python
from fastapi import Request

@app.get("/api/me")
def me(request: Request) -> dict:
    # Injected by the SSO proxy; absent when SSO is off or the path is public.
    return {"email": request.headers.get("x-forwarded-email")}
```

The trust model — read this before using the headers for anything security-relevant:

- **Trustworthy only while SSO is enabled.** The proxy strips any client-sent
  `X-Forwarded-*` identity headers before injecting its own, so when SSO is on they
  cannot be spoofed. When SSO is **off** there is no proxy and a caller can send these
  headers themselves — so treat a missing/present header as *identity*, never as an
  access-control decision the platform made for you. An app whose data model **requires**
  identity should tell the owner to enable SSO, and refuse (or stay read-only) when the
  headers are absent.
- **Absent on public paths.** On `/health` and any owner-declared *Public paths* the
  proxy strips the identity headers instead of injecting them (those requests are
  unauthenticated by design).
- **The browser never sees them.** They're request headers to your *backend* only. A
  frontend that wants "signed in as …" should call a backend endpoint that echoes the
  header (like `/api/me` above).
- **Your own `Authorization` header still works.** The proxy doesn't touch the client's
  `Authorization` header on gated routes, so Bearer-token APIs keep working behind SSO.
- **Authorization is still yours.** SSO answers *who*; the app decides *what they may
  do*. The owner's Access-tab allowlist controls who gets in at all; anything finer
  (roles, per-user rows) is app logic keyed on `X-Forwarded-Email`.
- **Local dev:** no proxy runs locally, so the headers are absent — code a graceful
  fallback (anonymous mode, or a dev-only env var), or send the header yourself:
  `curl -H "X-Forwarded-Email: dev@example.com" localhost:8000/api/me`.

### Hosting an MCP server (or webhooks) behind Google SSO

If the app owner enables **Google single sign-on** (the portal's Access tab), every
request goes through an interactive Google sign-in — which non-browser clients (MCP
clients, webhook senders) cannot complete. The pattern:

- Mount the endpoint under a dedicated path, e.g. `POST /api/mcp` (MCP streamable-HTTP).
- Have the owner add that path to **Public paths** on the Access tab — the SSO proxy
  then passes it through without sign-in (the prefix covers everything below it).
- Because the path is now public, **your app must authenticate it itself** — e.g. require
  `Authorization: Bearer <token>` checked against a secret env var declared in
  `backend/.env.example` (marked `# secret`). MCP clients support custom headers, so
  users paste the token into their client config.

Apps without SSO enabled need none of this — but shipping the Bearer check anyway is
cheap insurance.

## Migration DDL: OceanBase gotchas

**This section applies only to `database: oceanbase` apps** — `postgres` and `mysql`
run the real engine, accept both shapes below, and are not linted for them.

Migrations run against **OceanBase in MySQL mode**, which rejects a few DDL shapes that
real MySQL accepts. A local MySQL/MariaDB happily applies them, so they surface only at
deploy time — and the failure is expensive: a failed migration leaves a `success=0` row in
the app's Flyway history, and because the platform runs plain `migrate` (no `repair`),
**every later deploy fails validation** (`Detected failed migration to version N`) until
that row is cleared. Fixing your SQL and redeploying is not enough on its own.

The two shapes below are now **rejected at VALIDATING**, before anything runs, so you get
a clear error instead of a wedged app. Don't rely on that as your only guard — write DDL
defensively anyway:

- **Never add a column and its foreign key in one `ALTER TABLE`.**
  `ALTER TABLE t ADD COLUMN c …, ADD CONSTRAINT … FOREIGN KEY (c) …` fails with error
  5031 `Column not found` — the FK clause can't see the column being added in the same
  statement. Split it into two `ALTER TABLE` statements: add the column first, then the
  constraint.
- **Never use a self-referencing foreign key with `ON DELETE CASCADE`** (a column
  referencing its own table, e.g. `parent_id` → same table's `id`). OceanBase rejects
  it outright. Use a plain indexed column instead and do the cascade delete in
  application code.
- **One logical change per statement.** Combined multi-clause `ALTER`s are where OB's
  MySQL-compat gaps surface; small statements also fail atomically, which keeps a
  failed migration recoverable.

### Recovering from a failed migration

If a deploy fails at MIGRATING with `Detected failed migration to version N`, the app is
stuck until you clear it — but you can do that yourself:

1. **Portal → your app → Database tab.** A banner names the failed migration and lists any
   tables it had already created before it died. Click **Repair migration history**
   (owner or admin). That runs `flyway repair`, which clears the failed row.
2. **Fix the migration file in place.** It never succeeded anywhere, so editing it is
   safe — no new version number, no checksum problem.
3. **Deal with what it left behind.** DDL auto-commits, so any table/column the migration
   created before failing is still there, and the corrected migration re-runs *from the
   start* — it will hit `table already exists` unless you either drop those objects or
   make the migration re-runnable (`CREATE TABLE IF NOT EXISTS`, and check before
   `ALTER`). The banner lists them with row counts so you know what's safe to drop.
4. **Then deploy.** Repair before you push the fix: pushing an unfixed migration just
   half-applies it again and re-blocks deploys.

## Other backend stacks

The contract is behavioural and stack-agnostic, so a Go (or Node, Rust, Ruby, …) backend is
fine as long as it `EXPOSE`s 8000, serves `GET /health`, routes its API under `/api`, and
ships a Dockerfile. Two things bite non-Python backends:

**1. `DATABASE_URL` is a `mysql://` URL — convert it to your driver's DSN.** It points at
OceanBase (MySQL-wire), e.g.
`mysql://app_x%40substrait:pw@oceanbase.substrait.svc.cluster.local:2881/app_x` (the `%40`
is a URL-encoded `@` in the username). Go's `go-sql-driver/mysql` does **not** accept that
URL form: it needs `user:pass@tcp(host:port)/db`. Passing the host bare yields the startup
error `default addr for network 'oceanbase.substrait.svc.cluster.local:2881' unknown`
(the driver reads `host:port` as a network name). Parse the URL and rebuild the DSN —
`net/url` decodes the `%40` for you:

```go
import (
    "database/sql"
    "fmt"
    "net/url"
    "os"

    _ "github.com/go-sql-driver/mysql"
)

func openDB() (*sql.DB, error) {
    u, err := url.Parse(os.Getenv("DATABASE_URL")) // mysql://user:pass@host:2881/db
    if err != nil {
        return nil, err
    }
    pw, _ := u.User.Password()
    // u.Host = "host:2881", u.Path = "/db"; the tcp(...) wrapper is required.
    dsn := fmt.Sprintf("%s:%s@tcp(%s)%s?parseTime=true", u.User.Username(), pw, u.Host, u.Path)
    return sql.Open("mysql", dsn)
}
```

(Node's `mysql2`, Rust's `sqlx`, etc. accept the `mysql://` URL directly — only the Go
driver needs the `tcp(...)` rewrite. Whatever the stack, it's **MySQL**, never Postgres.)

**2. DDL stays in Flyway migrations**, same as every stack: schema lives in
`backend/resources/db/migration/V*.sql` (MySQL/OceanBase dialect); your code only reads and
writes rows — it never `CREATE TABLE`s.

A minimal Go backend Dockerfile (`cicd/Dockerfile.backend`, built from the **repo root**,
so `COPY` paths are repo-root-relative):

```dockerfile
FROM golang:1.23 AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -o /app/server .

FROM gcr.io/distroless/static-debian12
COPY --from=build /app/server /server
EXPOSE 8000
CMD ["/server"]
```

Serve `GET /health` (200, the readiness probe) and your API under `/api/...` on port 8000,
exactly as the FastAPI scaffold does. Everything else in this contract — one ingress host,
`/api` routing, `backend/.env.example` for custom config, source-only zip — is unchanged.

## Pre-upload checklist

- [ ] `cicd/Dockerfile.backend` (or another backend Dockerfile) is present — `EXPOSE 8000`, serves `GET /health`, API under `/api`.
- [ ] If `frontend/` is present, `cicd/Dockerfile.frontend` (+ `cicd/nginx.conf`) is shipped too — serves the SPA on port 80.
- [ ] (Python scaffold only) backend deps install wheels-only (`--only-binary=:all:`), or you've added the toolchain for any source-built dep.
- [ ] Backend API routes are under `/api` (so the ingress routes them to the backend).
- [ ] Frontend (if any) calls the API via relative `/api` paths, not an absolute URL.
- [ ] Build-time `VITE_*` vars (if any) are in a committed `frontend/.env.production` — public values only, no secrets, and `VITE_API_URL` is left unset. If `.gitignore` ignores `.env*`, it un-ignores `.env.production`.
- [ ] No `k8s/` (the platform owns it).
- [ ] Schema changes only in `backend/resources/db/migration/V*.sql`.
- [ ] Migration DDL avoids the OceanBase gotchas (no column + FK in one `ALTER`; no self-referencing FK with `ON DELETE CASCADE`) — see *Migration DDL: OceanBase gotchas*.
- [ ] Custom env vars/secrets declared in `backend/.env.example` (secrets marked `# secret`); no real secret values committed.
- [ ] Secrets read from env, none committed.
- [ ] Zip is source-only and under 16 MB.
