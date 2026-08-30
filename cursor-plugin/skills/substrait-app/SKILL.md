---
name: substrait-app
version: 2026.08.30.104958
description: Build apps that deploy on the Substrait platform via upload mode (GitHub-connected apps deploy from their pushed branch with the same commands — no zip). Use whenever the user asks to build, scaffold, or package an app "for Substrait", "to upload to Substrait", or for the Substrait upload/deploy contract. The zip contains app code plus its Dockerfile(s): a backend that serves GET /health on port 8000 with its API under /api (any language or framework — the scaffold uses FastAPI) and a cicd/Dockerfile.backend, plus Flyway migrations, and an optional frontend served on port 80 (any framework — the scaffold uses React + Vite + Tailwind) with a cicd/Dockerfile.frontend. The platform generates only the Kubernetes manifests, so you never write k8s or deal with the app slug.
---

# Substrait upload-mode apps

Substrait deploys an uploaded `.zip` to a sandbox namespace by building your image(s) from
**your own Dockerfile(s)**, running Flyway migrations, and applying the Kubernetes
manifests it generates. The contract is **behavioural and stack-agnostic**: your app works
as long as its Dockerfile exposes the right port and serves the right paths. **Use any
language or framework you like** — Python, Node, Go, Rust, Ruby, … for the backend; React,
Vue, Svelte, htmx, server-rendered HTML, … for the frontend. The platform generates **only
the Kubernetes manifests** and binds them to the slug it mints; you never write k8s.

A ready-made **FastAPI + React/Vite** scaffold lives in `reference/templates/` — it's the
fastest start and a working reference, **not a requirement**. Swap in whatever stack you
want, as long as it meets the contract below.

## The deploy contract (the only hard requirements)

Everything the platform actually enforces is here, and it's all stack-neutral:

| Requirement | Detail |
|---|---|
| **Backend Dockerfile** | `cicd/Dockerfile.backend` (or `cicd/Dockerfile`, or `backend/Dockerfile`). Must `EXPOSE 8000`, serve **`GET /health`** (returns 200 — the readiness probe), and serve the API under **`/api`**. |
| **Frontend Dockerfile** | Required **only when you ship a `frontend/`**: `cicd/Dockerfile.frontend` (or `frontend/Dockerfile`). Must serve the built site on **port 80**. |
| **Database** | **Declared explicitly** in `substrait.yaml`: `database: oceanbase` (shared HA cluster, MySQL wire), `database: postgres` or `database: mysql` (your app's own single-node pod + disk). The platform provisions it and injects `DATABASE_URL` **only when declared** — no declaration → no database, no `DATABASE_URL`, and shipping migrations without one **fails validation**. Pick with *Choosing an engine* below. |
| **Migrations** | All DDL in **Flyway** SQL at `backend/resources/db/migration/V*.sql`, in your engine's dialect — never `CREATE TABLE` from application code. Requires a `database:` declaration. **On OceanBase only**, some valid-MySQL DDL is rejected (a failed migration blocks all later deploys until repaired) — see *Migration DDL: OceanBase gotchas* in `reference/deploy-contract.md`. |
| **App manifest** | REQUIRED — a **`substrait.yaml`** at the repo root with a `description:` (1–3 sentences: what the app does and who it's for — recorded onto the app at deploy; a missing manifest or description fails validation). The database (`database: oceanbase`) and backing services (redis / kafka / qdrant / object-storage) are declared in the same file — a used database/service MUST be declared. See *App manifest* below. |
| **No k8s, no slug** | Never write `k8s/` or reference the app slug — the platform owns both. Any `k8s/` you include is discarded. |
| **Source only, ≤ 16 MB** | Exclude `node_modules/`, `.venv/`, `dist/`, `__pycache__/` and other build artifacts. |

That is the whole contract. The routing model that makes it work: the app deploys behind
**one ingress host** — `/api` → backend, everything else → frontend (or → backend when you
ship no `frontend/`; see *Frontend* below). So your backend serves its API under `/api`,
and your frontend (if any) calls it same-origin via relative `/api` paths.

Project layout — the `cicd/` Dockerfile(s) and `substrait.yaml` are the only files the
platform requires; the rest below is the scaffold's FastAPI/React default, which you can
replace wholesale:

```
cicd/
  Dockerfile.backend                # REQUIRED — builds the backend image (EXPOSE 8000, GET /health, /api)
  Dockerfile.frontend               # REQUIRED when you ship frontend/ — serves the built site on port 80
  nginx.conf                        # scaffold's static-site server; referenced by the scaffold Dockerfile.frontend
backend/                            # your backend, in any language (scaffold: FastAPI)
  ...                               # scaffold ships main.py + requirements.txt; yours can be anything
  storage.py                        # OPTIONAL — scaffold's object-storage helper; inert until you import it
  .env.example                      # OPTIONAL — declare custom env vars + secrets (prefilled in the portal)
  resources/db/migration/V*.sql     # OPTIONAL — Flyway migrations (MySQL/OceanBase dialect)
frontend/                           # OPTIONAL — any framework (scaffold: React + Vite + Tailwind)
substrait.yaml                      # REQUIRED — app description (+ database + backing services)
docker-compose.yml                  # OPTIONAL — local-dev DB + Flyway runner; ignored by the platform
.claude/settings.json               # OPTIONAL — pre-registers the Substrait plugin for Claude Code; ignored by the platform
```

## Runtime environment

The platform injects these via the `app-secrets` Kubernetes Secret — read them from the
environment, never commit them:

- **`DATABASE_URL`** — injected **only when the manifest declares a `database:`**. Its
  scheme follows the engine: `mysql://…` for `oceanbase` (and `mysql`),
  `postgresql://…` for `postgres`. On OceanBase it is **MySQL-wire compatible**
  (`mysql://user:pass@host:2881/db`).
  **On `oceanbase` and `mysql`** use a MySQL driver, never PostgreSQL (no `asyncpg`,
  no `$1`):
  - **Python (scaffold):** `asyncmy` with `%s` placeholders — see `reference/templates/backend/main.py`.
  - **Node / Rust / etc.:** most drivers (`mysql2`, `sqlx`, …) accept the `mysql://` URL directly.
  - **Go:** `go-sql-driver/mysql` needs the address wrapped in `tcp(...)`; parse the URL and
    rebuild the DSN, or it fails at startup with `default addr for network '…:2881' unknown`.
    Full snippet + a Go backend Dockerfile: `reference/deploy-contract.md` → *Other backend stacks*.

  **On `postgres`** use a Postgres driver — `asyncpg` or `psycopg` in Python, with
  `$1` placeholders — against the `postgresql://` URL. (The scaffold's `main.py` is
  written for MySQL wire, so a Postgres app rewrites its data layer accordingly.)
- **`JWT_SECRET`**
- **Per declared backing service** (see next section): **`REDIS_URL`**, **`KAFKA_BROKERS`**,
  **`QDRANT_URL`**, **`OBJECT_STORAGE_BUCKET`** — injected **only** when the service is
  declared in `substrait.yaml`.
- **`SUBSTRAIT_EGRESS_URL`** / **`SUBSTRAIT_EGRESS_TOKEN`** — injected once a data owner
  approves the app for a company API in the API Library. Together they are how the app
  calls that API: the platform holds the real credential and attaches it. Both are
  RESERVED: declaring either in `.env.example` is silently ignored (the deploy still
  succeeds, the variable just never appears), so do not declare them and do not expect
  an error to tell you. See *The API Library* below.

Whatever the stack, the database is whichever engine the manifest declares — use its
driver (a **MySQL** driver for `oceanbase`), and keep all schema in Flyway migrations
(below); your code only reads and writes rows.

## App manifest (`substrait.yaml`): description & backing services

**`substrait.yaml`** at the repo root is **required** and carries three things: the app's
**description** (what it does and who it's for — recorded onto the app at each deploy
and shown in the portal and the API Library; a missing file, a missing description, or
the scaffold's untouched placeholder all **fail validation**, so write a real one and
keep it current), the app's **database** (declared explicitly — see below), and any
**backing services** the app needs — the platform provisions those next to the app and
injects the connection env var. Installing a client library alone does nothing;
**the manifest is the only trigger**.

```yaml
description: >
  Tracks team leave requests with an approvals workflow; managers approve or
  reject, and the team calendar shows who's out. For people managers and HR.

database: oceanbase        # explicit — no declaration, no database (see below)

services:
  redis: {}                # cache/queue        → injects REDIS_URL   (redis://redis:6379/0)
  kafka:                   # Kafka-compatible   → injects KAFKA_BROKERS (kafka:9092)
    persistent: true       #   (single-node Redpanda under the hood)
  qdrant: {}               # vector database    → injects QDRANT_URL  (http://qdrant:6333)
  object-storage: {}       # private file bucket → injects OBJECT_STORAGE_BUCKET
```

- **`database:` is explicit and separate from `services:`.** The platform provisions
  the app's database and injects `DATABASE_URL` **only when the manifest declares one**
  (`oceanbase`, `postgres` or `mysql` — see *Choosing an engine*). An app with no
  declaration gets no database and no `DATABASE_URL`; shipping Flyway migrations
  without the declaration fails validation (they'd have nothing to run against).
  Removing the declaration from a deployed app never deletes its database or severs
  its connection string — the data is dropped only when the app itself is deleted.
  **The engine cannot be changed once deployed**: there is no data migration between
  engines, so a changed `database:` value fails the deploy rather than silently
  handing the app a different, empty database.
- Those four are the whole `services:` catalog; `persistent` applies only to the three
  pod services — `object-storage` takes no options. Anything else fails validation with
  the fix in the message.
- **Pod services are ephemeral by default**: a service pod restart wipes its data — treat
  redis as a cache, recreate qdrant collections on startup if missing. Set
  `persistent: true` for a disk that survives restarts and redeploys (kafka log: 10Gi,
  qdrant: 5Gi, redis AOF: 1Gi — fixed sizes).
- Removing a **pod** service from the manifest removes it on the next deploy (its disk is
  kept until the app itself is deleted; re-declaring `persistent: true` re-adopts the data).
  Deleting the whole `substrait.yaml` is not an option — the file is required.
- **`object-storage` is durable, and removing it deletes nothing** — see *Object storage
  (files)* below for its lifecycle.
- kafka favours a small footprint over strict durability (relaxed fsync) — fine for
  events/jobs; don't treat it as a system of record.
- The pod services are reachable **only from inside the app's own namespace** at
  `redis:6379`, `kafka:9092`, `qdrant:6333/6334` (gRPC). Need Pinecone or another SaaS
  instead? Just declare its API key in `.env.example` — no manifest entry.
- The manifest may also carry an **optional `scaffold_version:`** — the version of this
  skill the app was built with, which the platform records on each deploy (it powers
  scaffold-staleness reporting). **Don't write or edit it by hand**: `/substrait:deploy`
  stamps it automatically from the installed skill. Manifests without it stay valid.

### Choosing an engine

| | `oceanbase` | `postgres` / `mysql` |
|---|---|---|
| **Where** | Shared, multi-zone HA cluster the platform operates | A **single-node pod with its own 10Gi disk, in your app's namespace** |
| **Wire protocol** | MySQL (use a MySQL driver) | Native Postgres / MySQL |
| **Backups** | Nightly platform dumps | **None** — nothing is backed up for you |
| **Portal tooling** | Database tab: browse, run migrations, repair, reset | Not available (deploys still run migrations normally) |
| **Best for** | Anything you'd be upset to lose | Apps that need real Postgres/MySQL features, internal tools, prototypes |

Default to **`oceanbase`** — it is the production-grade, backed-up, fully-tooled
option. Choose `postgres` or `mysql` when the app genuinely needs that engine (e.g.
Postgres-specific SQL, JSONB, extensions, or an ORM that only speaks Postgres), and
accept the tradeoff: **one replica, no HA, no platform backups, and no Database-tab
tooling**. The pod restarts with the node it runs on, and its disk survives redeploys,
rollbacks and undeclaring the database — but if the data matters, arrange your own
export.

`mysql` also sidesteps the OceanBase DDL gotchas below — it is real MySQL 8, so the
lint that rejects those two shapes doesn't apply to it.

### Object storage (files)

Declaring `object-storage: {}` gets the app a **private bucket of its own** and one injected
variable, **`OBJECT_STORAGE_BUCKET`** (the bucket name). Use it for anything a database row
shouldn't hold — uploads, generated PDFs, images, exports.

```python
import storage                       # backend/storage.py, shipped in the scaffold

key = storage.safe_key(tenant_id, user_id, "report.pdf")   # never a raw client filename
storage.put_bytes(key, pdf_bytes, content_type="application/pdf")
data = storage.get_bytes(key)
storage.list_keys(f"{tenant_id}/")
storage.delete(key)                  # a no-op if it's already gone

link = storage.download_url(key)     # time-limited URL — let the browser fetch it directly
```

- **Nothing to configure.** The pod authenticates to the bucket itself; there is no key, no
  secret and no credential to put in `.env.example`. Read `OBJECT_STORAGE_BUCKET` and go.
- **Any language works.** The scaffold's `backend/storage.py` wraps Google's
  `google-cloud-storage` SDK, but the bucket is plain GCS — use whichever GCS client your
  stack has, and let it pick up Application Default Credentials.
- **Isolation is enforced by the platform**, not by your code: an app can reach its own
  bucket and no other, and buckets can never be made public (`make_public()` fails by
  design — that failure is the platform working).
- **Durable, and it outlives the manifest.** Files survive redeploys, rollbacks, and even
  removing the declaration (the variable keeps being injected and the bucket stays yours;
  you just get a warning). The bucket is deleted only well after the whole **app** is
  deleted.
- **It is not a backup.** Keep your object keys in the database — that's the index; the
  bucket is the bytes.
- **Big files need not pass through your pod.** `download_url()` and `upload_url()` mint
  **time-limited URLs** (15 minutes for downloads, 5 for uploads) that the browser uses
  directly — signed with the app's own identity, so still no key anywhere. Authorize the
  request *before* you mint one and keep the expiry short: a signed URL bypasses your app
  and **cannot be revoked**.
- **Multi-tenant apps must prefix keys by tenant** and re-validate that prefix on every
  read, write and sign. The platform isolates you from *other apps*; it cannot isolate your
  own tenants from each other.
- **Locally** it's `docker compose up -d gcs` (fake-gcs-server) plus two exports — the same
  code, unchanged. The emulator does not verify signatures, so signed flows are only really
  tested once deployed. See `reference/local-dev.md`.

Full guide, including a copy-paste FastAPI upload/download pair and the rules for signed
URLs: `reference/object-storage.md`.

## Declaring custom env vars & secrets

Your app's own config — API keys, feature flags, third-party credentials — goes in a
**`backend/.env.example`** (root `.env.example` also works). On upload the platform parses
it and **pre-creates each entry** under the app's Settings (Environment variables /
Secrets), so the user just fills in real values in the portal. Format:

```
APP_GREETING=Hello from Substrait     # env var, prefilled with "Hello from Substrait"
THIRD_PARTY_API_KEY=     # secret      ← mark a secret with a trailing "# secret"
```

- One `NAME=value` per line; the value is the prefilled placeholder (may be empty).
- Add a trailing `# secret` to store it write-only (masked in the portal).
- Do **not** list `DATABASE_URL`, `JWT_SECRET`, or the backing-service vars
  (`REDIS_URL`, `KAFKA_BROKERS`, `QDRANT_URL`, `OBJECT_STORAGE_BUCKET`) — the platform
  injects those.
- Read them at runtime from the environment; never commit real secret values.
- Re-uploading only adds new keys — it never overwrites a value the user has set in the portal.
- Real values are set either on the app's Settings page in the portal or from the linked
  project with **`/substrait:env`** (list / set / unset — secrets write-only; live-applies
  to a running app in seconds).

## User identity (Google SSO)

If the app owner enables **Google single sign-on** (the portal's Access tab), the
platform's auth proxy injects the signed-in user's identity into every gated backend
request — **`X-Forwarded-Email`** (plus `X-Forwarded-User`) — so an app that needs to
know who's using it needs no OAuth flow or login page of its own: read the header and
key user data on the email. Three rules:

- Trustworthy **only while SSO is enabled** (the proxy strips client-sent values; with
  SSO off, anyone can send these headers) — and absent on public paths and in local dev,
  so degrade gracefully (anonymous mode) when the header is missing.
- The **browser never sees the headers** — expose a backend endpoint (e.g. `/api/me`,
  the scaffold ships one) for the frontend to ask "who am I?".
- SSO answers *who*; anything finer (roles, per-user rows) is your app's logic.

See `reference/deploy-contract.md` → *User identity under Google SSO* for the full trust
model and snippet.

## Frontend (full-stack)

A frontend is optional but, when present, is **deployed alongside the backend** in the same
sandbox namespace behind **one ingress host**: `/api` → backend, everything else →
frontend. **Use any framework** — the scaffold uses **React + Vite + Tailwind** (start from
`reference/templates/frontend/`), but anything that builds to a site served on **port 80**
works (Vue, Svelte, Astro, plain static HTML, a server-rendered app, …). Whatever you pick:

- **Call the backend same-origin via relative `/api` paths** (`fetch("/api/...")`). Don't
  hardcode an absolute API URL — the ingress routes `/api` to the backend on the same host.
- **Serve the built output on port 80** (the scaffold serves the static bundle via nginx in
  `cicd/Dockerfile.frontend`).

If you ship **no `frontend/`**, the platform routes *all* traffic (including `/`) to the
backend, so a backend-only app must serve its own root/pages itself — a pure-API backend
will return its own 404 on `/` (the app is reachable, just rootless). No frontend Dockerfile
is needed in that case.

### Build-time frontend env vars

This applies if your frontend is a **bundled SPA** (Vite, CRA, etc.) that inlines env vars
at build time — skip it for server-rendered or runtime-configured frontends. Bundlers inline
`import.meta.env.VITE_*` (or equivalent) at **build time**, but the portal's env vars are
injected into the **backend at runtime only** — they never reach the frontend build. To set
build-time frontend vars (e.g. an OAuth client ID), commit a **`frontend/.env.production`**
(Vite auto-loads it during `npm run build`). Three rules:

- ⚠️ **Public, non-secret values only.** It's committed to git *and* baked into the JS bundle
  every visitor downloads. Secrets (API keys, client *secrets*) → `backend/.env.example`.
- **Never set `VITE_API_URL`** — the scaffold forces it to `""`; use relative `/api` paths.
- If your `.gitignore` ignores `.env*`, un-ignore this file: add `!.env.production`.

See `reference/deploy-contract.md` → *Build-time frontend env vars* for the full rationale.

## If you use the Python/FastAPI scaffold

These are conveniences of the **default scaffold**, not contract requirements — they don't
apply if you pick another stack:

- **Typed responses on every endpoint.** Declare a Pydantic `response_model` (or typed
  return annotation) on every `/api` route — the scaffold's endpoints show the pattern.
  This is what makes the app **self-describing**: FastAPI's `/openapi.json` then carries
  real field names and types, which feed the portal's API tab and the **API Library**
  other builders design against. A bare `return {...}` publishes "object, any fields" —
  an API nobody can build on. (Any stack can instead ship an authored **`openapi.json`
  at the repo root** — the platform records it at deploy as the app's published API
  description, taking precedence over the runtime-harvested spec. `/substrait:deploy`
  authors one automatically; connect-mode repos can commit one by hand.)
- **Wheels-only installs.** The scaffold's `cicd/Dockerfile.backend` uses
  `pip install --only-binary=:all:` on a compiler-less `python:3.12-slim` base, so a dep with
  no wheel fails fast and legibly instead of dying in a cryptic source build. Need a source
  build? Pin a version that ships a wheel, or add the toolchain and drop the flag.
- **Heavy deps / GPU torch.** The platform's shared builders are sized for lean images;
  pin CPU-only `torch` (the cluster has no GPUs). See `reference/deploy-contract.md` →
  *Build resource ceiling*.

## Running locally

Local dev is **not** part of the deploy contract, but the scaffold is locally runnable.
Run a local database of the **same engine you declared** so the driver, placeholders and
Flyway migrations all run unchanged (`oceanbase` → a local **MySQL/MariaDB**) — **not SQLite** (different
driver, placeholders and dialect; the migrations won't apply). The scaffold ships a root
`docker-compose.yml` (a `db` + one-shot `migrate` service); for the FastAPI/Vite default:

```bash
docker compose up -d db && docker compose run --rm migrate   # MySQL + migrations
cd backend  && DATABASE_URL="mysql://root:root@localhost:3306/app" uvicorn main:app --reload
cd frontend && npm install && npm run dev                     # Vite proxies /api -> :8000
```

On another stack, run the backend however that stack runs (still on `:8000`, reading
`DATABASE_URL`) — just keep a MySQL-wire DB. The platform ignores `docker-compose.yml` on
upload. Already have a MySQL-wire DB (e.g. a local TiDB on `:4000`)? Skip the compose file
and point `DATABASE_URL` at it. See `reference/local-dev.md` for the full guide.

## Workflow

1. Pick a stack (or start from `reference/templates/` for the FastAPI + React default).
2. Write the backend so it listens on **port 8000**, serves **`GET /health`**, and serves its
   API under **`/api`**. Ship a `cicd/Dockerfile.backend` that builds it and `EXPOSE`s 8000.
3. (Optional) Build a frontend in `frontend/` calling the API via relative `/api` paths, and
   ship a `cicd/Dockerfile.frontend` that serves it on **port 80**.
4. Using a database? Declare it in `substrait.yaml` (`database: oceanbase` unless the
   app needs real Postgres/MySQL — see *Choosing an engine*) and put every schema
   change in a new `backend/resources/db/migration/V*.sql`, in that engine's dialect
   (on OceanBase, mind the DDL gotchas in `reference/deploy-contract.md`). No
   database? Omit the key and ship no migration files.
5. List any custom config the app reads from env in `backend/.env.example` (mark secrets `# secret`).
6. Do **not** create `k8s/` — the platform generates only that, and the slug.
7. Record the deploy contract in the project's memory file: copy
   `reference/claude-md-snippet.md` **verbatim** (markers and version tag included) into
   `CLAUDE.md` (`AGENTS.md` in Cursor) — create the file, or append if it exists —
   replacing the `__SUBSTRAIT_APP_LINK__` placeholder with
   `not linked yet — run /substrait:link`. If the file already contains the
   `substrait-app contract` block, leave that block untouched (the plugin's link/deploy
   scripts own its updates).
8. When asked to package: zip the project root, source only, ≤ 16 MB.

> **GitHub-connected apps** (created in the portal via *Connect to GitHub*) never ship
> a zip: `/substrait:deploy` *triggers* Substrait to pull the app's connected branch.
> Everything above still applies, but the artifacts (`openapi.json`, `substrait.yaml`,
> migrations, Dockerfiles) must be **committed and pushed** before deploying — the
> deploy script refuses a dirty tree, the wrong branch, or an unpushed HEAD, and the
> server verifies the pushed commit SHA. Pushing alone does **not** deploy unless the
> app's auto-deploy toggle is enabled in the portal.

See `reference/deploy-contract.md` for the full spec, `reference/local-dev.md` for running
locally, `reference/object-storage.md` for the file bucket, and `reference/templates/` for
the copy-paste-ready FastAPI + React scaffold.

## The API Library (designing against existing APIs)

The portal keeps a design-time **API Library**: admin-registered company APIs (with
full OpenAPI specs and access notes) plus every deployed Substrait app's endpoint
inventory — and, once an app has deployed with a servable spec, its full OpenAPI doc
too (`spec app <slug>`; works even for SSO-gated apps, whose public `/openapi.json`
is unreachable). Browse it with `/substrait:library` (or `substrait-library.sh
list|show|spec`) to discover what data already exists and design an app that consumes
it. Company APIs are **brokered**: once a data owner approves the app, it calls them
through the platform gateway at `$SUBSTRAIT_EGRESS_URL/<entry-slug>/…` with
`$SUBSTRAIT_EGRESS_TOKEN`, and the platform attaches the real credential — so never
design an env var to hold one. Other Substrait apps are still called directly. While
building, you can also see a company API's **real responses** from the editor —
`substrait-library.sh call <slug> GET <path>` — once the data owner has granted the
USER development access (`… request <slug> --reason "…"`; read-only, time-boxed). Full
guide: `reference/api-library.md`.

## Project memory (CLAUDE.md)

Substrait projects carry a marker-delimited **"Substrait deployment" block** in their
`CLAUDE.md` (`AGENTS.md` in Cursor) with the contract essentials, so sessions that never
load this skill still build compliant changes. The content is this skill's
`reference/claude-md-snippet.md`. Scaffolding writes it (Workflow step 7, with a
"not linked yet" placeholder), and the plugin's link/deploy scripts then maintain it
deterministically: `link` adds or updates it (filling in the linked app), `deploy`
refreshes an outdated one. Don't hand-edit inside the block — it's replaced on update —
and treat a user's deletion of the block as an opt-out.

## Updating this skill

This skill ships inside the **`substrait` Cursor plugin** (it's the plugin's bundled
skill, alongside the `/substrait:link` and `/substrait:deploy` commands). Update it the
way you update any Cursor plugin — from the marketplace you installed it from (the
`substrait` plugin in the `substrait-build/substrait-cursor-plugin` marketplace).

The plugin doesn't self-update, but a `sessionStart` hook checks once a day (fail-silent)
whether a newer version is published and, if so, nudges you to update — it never changes
any files itself.
