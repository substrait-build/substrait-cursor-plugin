# Object storage (files)

Databases are the wrong home for bytes. Declare `object-storage` and the app gets a
**private bucket of its own** for uploads, generated documents, images and exports — the
same code locally and deployed, and nothing to configure either way.

## What you get

- **One private bucket per app, per environment**, and one injected environment variable,
  **`OBJECT_STORAGE_BUCKET`**, holding its name. An app with `production` and `staging`
  has two buckets and two identities; each pod can reach only its own environment's,
  so a staging deploy can never read or overwrite production's files.
- **No credential.** The pod is granted access to its bucket by the platform. There is no
  key to mount, no secret to rotate and nothing about storage that belongs in
  `backend/.env.example`.
- **Time-limited links.** The app can mint short-lived URLs that let a browser download an
  object, or upload one straight into the bucket, without the bytes passing through your
  pod — and without a credential of yours in the link. See *Time-limited links* below.
- **Isolation the platform enforces.** An app reaches its own environment's bucket and no
  other — not another app's, and not another environment of its own. Buckets can never be
  made public: `make_public()` and ACL calls **fail** — that failure is the platform
  working, not a bug to route around.
- **Durable storage.** Files survive redeploys, rollbacks and manifest edits. Nothing but
  deleting the app or the environment (and then waiting out a grace period) removes them.
- **A new environment starts EMPTY.** Creating `staging`, or taking an app live, gives that
  environment a fresh bucket — nothing is copied from a sibling, exactly as its database
  is not. Read `OBJECT_STORAGE_BUCKET`; never hard-code a bucket name, and never assume a
  key that exists in one environment exists in another.

It is plain Google Cloud Storage, so **any language works** — use whatever GCS client your
stack has and let it pick up Application Default Credentials.

## Declare it

```yaml
# substrait.yaml
description: >
  Collects field-inspection photos and produces a signed-off PDF report per site visit.

services:
  object-storage: {}
```

That is the whole declaration — it takes **no options** (`persistent` applies only to the
pod services, and the bucket is durable regardless). Installing a client library does
nothing on its own: **the manifest is the only trigger**. `OBJECT_STORAGE_BUCKET` appears
in the app's environment on the next deploy.

One manifest covers every environment: each one the app is deployed to provisions its own
bucket on its first deploy that declares the service, and `OBJECT_STORAGE_BUCKET` carries
that environment's name.

## Reading and writing

The scaffold ships `backend/storage.py`, a small wrapper around the SDK — eight public
functions: `safe_key`, `put_bytes`, `get_bytes`, `exists`, `delete`, `list_keys`,
`download_url`, `upload_url`. It is inert until you import it, and it is the only file in
your app that knows the storage provider.

```python
import storage

key = storage.safe_key(tenant_id, user_id, "report.pdf")
storage.put_bytes(key, pdf_bytes, content_type="application/pdf")

data    = storage.get_bytes(key)      # bytes
present = storage.exists(key)         # bool
keys    = storage.list_keys(f"{tenant_id}/")
storage.delete(key)                   # no-op if it's already gone
```

`safe_key()` is not optional politeness. **Never use a client-supplied filename as a key**:
a `/` inside it crosses into another prefix and `..` means nothing to GCS, so a name like
`../other-tenant/secret.pdf` lands exactly where it says. Derive keys yourself
(`f"{tenant_id}/{user_id}/{uuid4()}"`), keep the original filename as your own database
column, and run every key through `safe_key()`.

It **raises `ValueError`** rather than sanitising, and its charset is deliberately narrower
than filenames are: `A-Z a-z 0-9 . _ -` plus `/` as the separator, up to 512 characters. A
space, an accent, `+`, `%` or `#` is rejected — `my report.pdf`, `résumé.pdf` and `a+b.pdf`
are all `ValueError`, not escaped. That is the point: a key you have to escape is a key you
will one day forget to escape. Feed it your own derived key and it never fires; wherever a
client can still influence what goes in, catch the `ValueError` and answer **400**, so a name
someone typed can never become a 500.

Two rejections are worth knowing by name, because in both the shape of a key changes under
you rather than an obviously bad character being caught:

- **An empty part is an error, not a part to skip.** `safe_key(tenant_id, name)` with an
  empty `tenant_id` does not fall back to writing `name` at the bucket root — it raises. It
  has to: `?tenant_id=` is a valid empty string, and a resolver that returns `""` for a caller
  it cannot place would otherwise put every such caller's objects in one unprefixed pile
  outside all your tenants. A prefix that can vanish is not a boundary.
- **`.` and `..` are rejected as whole path segments**, not as substrings. So `a/./b` and
  `x/../y` are refused while the ordinary `report..v2.pdf` is accepted. Refusing a dot segment
  *inside* a name is `safe_key()` being stricter than GCS on purpose — `a/./b` is a legal GCS
  object name that Google only recommends against, and a key whose meaning depends on whether
  something resolved it as a path is not worth the ambiguity.

Separately, `safe_key()` refuses every name **GCS itself** rejects with `Invalid argument`,
because `fake-gcs-server` stores all of them happily and a key like that would fail for the
first time in production:

| GCS rule | What `safe_key()` does |
| --- | --- |
| at most 1024 bytes | 512 characters, and the charset is ASCII — comfortably inside |
| no carriage return or line feed | not in the charset |
| never exactly `.` or `..` | the segment check above |
| never starts with `.well-known/acme-challenge/` | rejected as a reserved prefix |

Rolling your own client, in Python or any other language:

```python
from google.cloud import storage as gcs

client = gcs.Client()                                   # ADC — no credentials argument
bucket = client.bucket(os.environ["OBJECT_STORAGE_BUCKET"])
```

**Use `bucket()`, not `get_bucket()`.** `get_bucket()` fetches the bucket's metadata, which
needs a permission the app deliberately does not hold — it returns 403 even though every
read and write of your objects works. `bucket()` just names the bucket locally.

## A FastAPI upload/download pair

Copy-paste, and the only thing to change is where `tenant_of()` comes from:

```python
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

import storage

router = APIRouter(prefix="/api/files")

MAX_BYTES = 8 * 1024 * 1024
ALLOWED = {"application/pdf": ".pdf", "image/png": ".png", "image/jpeg": ".jpg"}


def tenant_of(request: Request) -> str:
    """YOUR tenant resolver: a session, a verified JWT claim, a header the SSO proxy set.

    Whatever it reads, it must RAISE for a caller it cannot place — never return "". A
    blank tenant is not a tenant, and it must not become one by accident: it would put
    every unplaceable caller's objects in a single unprefixed pile at the bucket root.
    (`safe_key()` refuses an empty part for exactly this reason, so a resolver that
    returned "" would surface as a 500 rather than as a silent leak — but a 401 raised
    here is the right answer, and it is yours to raise.)

    NOT a request parameter. A tenant id the client sends is a tenant id the client
    chooses.
    """
    raise NotImplementedError("resolve the caller's tenant from your own auth")


@router.post("")
async def upload(file: UploadFile, tenant_id: str = Depends(tenant_of)) -> dict:
    # Allowlist the type — never store user content under a type the browser executes.
    # Normalise first: browsers send `text/csv; charset=utf-8`, and case varies.
    ctype = (file.content_type or "").split(";")[0].strip().lower()
    ext = ALLOWED.get(ctype)
    if ext is None:
        raise HTTPException(415, f"unsupported type: {file.content_type}")
    data = await file.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "file too large")

    # The key is ours, not the client's. Record file.filename in your own table if you
    # want to show the original name.
    key = storage.safe_key(tenant_id, f"{uuid.uuid4()}{ext}")
    # `ctype` is the value YOU matched in the allowlist, not the header you were handed.
    # In a threadpool because this handler is `async def` — see below.
    await run_in_threadpool(storage.put_bytes, key, data, content_type=ctype)
    return {"key": key}


@router.get("/{tenant_id}/{name}")
def download(tenant_id: str, name: str, caller: str = Depends(tenant_of)) -> Response:
    # Authorize the tenant before reading anything, exactly as the signing endpoint does
    # below — a tenant id in the path is the caller's claim, not their identity.
    if tenant_id != caller:
        raise HTTPException(403, "not your tenant")
    # Re-validate the tenant prefix on the way out: the caller supplied part of the key.
    # safe_key() RAISES on anything outside its charset, and `name` came from the client —
    # so a request for "my report.pdf" is a 400, not an unhandled 500.
    try:
        key = storage.safe_key(tenant_id, name)
    except ValueError:
        raise HTTPException(400, "bad object name") from None
    if not storage.exists(key):
        raise HTTPException(404, "not found")
    return Response(
        storage.get_bytes(key),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{name}"'},
    )
```

Three things in there are load-bearing rather than stylistic. The **content-type allowlist**
stops a user storing `text/html` or `image/svg+xml` that would execute when someone opens
it, and what gets stored is the allowlisted value rather than the raw header.
**`Content-Disposition: attachment`** makes the browser download the file instead of
rendering it — do this on every route that hands back user-supplied bytes. And **the
`try/except ValueError`**: `name` is client-supplied, `safe_key()` rejects far more than a
filename picker will, and an uncaught `ValueError` is a 500 on an ordinary "résumé.pdf".

### Every storage call blocks — keep it off the event loop

`storage.py` is synchronous: each function makes an HTTP call, and on a 403 it sleeps
between retries as well, so a single call can take seconds. Both shapes above handle that,
and the difference is worth copying rather than reading past:

- `download` is a plain **`def`** — FastAPI runs those in a threadpool for you, so calling
  `storage.get_bytes()` straight from one is correct.
- `upload` is **`async def`** (it has to be: `await file.read()`), so it hops out with
  **`run_in_threadpool`**. `asyncio.to_thread` works too; `run_in_threadpool` uses the same
  bounded pool FastAPI already runs sync handlers in, so it queues rather than growing
  threads without limit.

Calling a storage function directly inside `async def` parks the whole worker — every other
request it is serving, `/health` included — for the duration. The failure that makes this
bite is exactly the one these helpers retry: a persistent signing 403 costs several IAM
round trips plus the backoff between them, on every request, until someone fixes the
configuration.

## Time-limited links (signed URLs)

Streaming every byte through your app spends a request slot per download and caps uploads
at whatever your handler can buffer. The alternative is a **signed URL**: a time-limited
link to exactly one object that the browser uses directly.

```python
link = storage.download_url(key, expires_seconds=900)         # GET,  15 minutes
put  = storage.upload_url(key, expires_seconds=300,           # PUT,   5 minutes
                          content_type="image/png",
                          max_bytes=8 * 1024 * 1024)
```

**Nothing to set up, nothing to rotate.** The pod has a Google service account of its own,
and the signature is produced by asking Google's IAM API to sign *as* that account — so no
private key is mounted, downloaded or stored anywhere, and there is no key material for you
to configure, protect or rotate. It works on the first deploy and keeps working.

### Signing is not authorization

A signed URL bypasses your app completely: no session, no middleware, no route handler.
Every check your download route would have made has to happen **before** you mint, in the
endpoint that mints:

```python
@router.get("/{tenant_id}/{name}/link")
def link(tenant_id: str, name: str, user=Depends(current_user)) -> dict:
    if user.tenant_id != tenant_id:          # authorize here — the URL never will
        raise HTTPException(403, "not your tenant")
    try:                                     # and build the key yourself, as always
        key = storage.safe_key(tenant_id, name)
    except ValueError:                       # `name` is the client's: 400, not 500
        raise HTTPException(400, "bad object name") from None
    return {"url": storage.download_url(key, expires_seconds=900)}
```

Two habits from *Reading and writing* matter twice as much here. **Derive the key
yourself** — never sign a path assembled from a client-supplied filename — and run it
through **`safe_key()`**, because a `/` in a name someone chose crosses into another
prefix and you are about to hand out a URL for whatever it lands on. If you show users
their original filenames, keep those in your own table (or as blob metadata) and sign the
derived key.

For a multi-tenant app, **re-validate the tenant prefix on every sign**, exactly as you do
on every read and write. The platform isolates your app from other apps; separating your
own tenants from each other is code you write, and the signing endpoint is the easiest
place to forget it.

### Handing out a download link

`download_url(key)` returns a URL anyone holding it can GET until it expires. The helper
always signs it with `Content-Disposition: attachment`, so the browser saves the file
instead of rendering it. That is not cosmetic: an uploaded `.html` or `.svg` rendered
inline would execute **on `storage.googleapis.com`**, in the origin your other objects live
in. If you sign URLs with your own client instead of the helper, set `response_disposition`
the same way on **every** GET you sign.

Pass `filename=` to control the saved name; the key's last segment is the default. Both the
disposition and the filename are properties of the *signature*, so neither exists locally —
see *Locally, signatures are not real*.

### Browser-direct uploads

`upload_url(key, …)` returns a URL a browser can `PUT` bytes straight to, so a large upload
never passes through your pod. Two constraints are baked into the signature, and the client
must match both or GCS rejects the request:

- **The content type.** The client sends `Content-Type:` exactly as signed. The helper
  refuses anything outside `storage.UPLOAD_CONTENT_TYPES` — extend that frozenset
  deliberately, and never sign a type the client chose. `text/html` and `image/svg+xml` are
  not on it and should never be: user content stored under an executable type is a
  stored-XSS bug waiting for someone to open it.
- **The size cap**, carried as `x-goog-content-length-range: 0,<max_bytes>` — the one extra
  header the client must echo back verbatim. A signed PUT without it is an unbounded write
  capability handed to a stranger. Re-validate the stored size afterwards anyway; the cap
  bounds the damage, it does not tell you what arrived.

```js
await fetch(signedUrl, {
  method: "PUT",
  headers: {
    "Content-Type": "image/png",                 // exactly what the server signed
    "x-goog-content-length-range": "0,8388608",  // exactly what the server signed
  },
  body: file,
});
```

The bucket's CORS is maintained by the platform and allows `GET`, `PUT` and `HEAD` from
**your app's own origins only** — its preview host and any custom domains. Uploads from
your own pages work with no configuration; a page on someone else's domain cannot read a
leaked URL's response from JavaScript.

### How long they live

The helper defaults to **900 seconds (15 minutes)** for downloads and **300 seconds
(5 minutes)** for uploads — shorter for uploads because the client asks for the URL
immediately before using it. The V4 format allows up to **7 days** and nothing in an app
should come close to it.

**A signed URL cannot be revoked.** Nothing you do afterwards takes one back — not deleting
the user's session, not changing their role, not deleting their account. The only remedies
are to delete the object or copy it to a new key and forget the old one. The expiry *is*
the access control, which is why it is measured in minutes.

Treat a live URL as a secret: **never log one**, and never put one in an email, a webhook
payload or anything else durable. A URL that appears in a page also escapes through
`Referer` headers and browser history.

### Locally, signatures are not real

`fake-gcs-server` implements neither IAM nor V4 signature verification, so `storage.py`
does not pretend otherwise:

- `download_url()` returns the emulator's **plain object URL** — no signature, no expiry and
  no `Content-Disposition`, so `filename=` and `expires_seconds=` do nothing locally and a
  PDF opens *inline* in the local Download button. Fine to build a UI against; just don't
  read the local behaviour as the deployed one.
- `upload_url()` raises `NotImplementedError` rather than returning a URL that would fail
  in a confusing way. Use `put_bytes()` locally and exercise the browser-direct path in a
  deployed environment.

The consequence worth internalising: **a signing bug cannot fail locally**, because
locally nothing verifies the signature. Expiry, the content-length range and cross-app
denial are only ever proven once deployed.

### When signing fails

Signing raises rather than returning a broken URL, and a failure is almost always a `403`
from the IAM signing API rather than anything wrong with your call. In the first minute
after a *first* deploy that is propagation (below), and `storage.py` retries it for you like
any other 403. Later than that, it is the platform's identity wiring, not your code — and
worth reporting.

Rolling your own signing? That 403 does **not** arrive as the SDK's `Forbidden`: signing
goes through the IAM signBlob API, and google-auth raises a `TransportError` carrying the
response body instead. A retry that catches only `Forbidden` will therefore never retry a
signing call — `storage.py` catches both (see `_retry_403`). The `TransportError` carries no
status code to switch on either, so `_is_403()` reads `error.code` out of the JSON body it
embeds, and only falls back to searching the text when there is no body to parse — a
fallback that can match a 403 which isn't one, at the cost of a couple of pointless retries
and nothing else.

Because a signing 403 that is *not* first-minute propagation is a configuration fault that
will not fix itself, `storage.py` retries signing **less** than it retries object IO —
fewer attempts, shorter backoff. Waiting longer would only make every affected request
slower.

Note that signing and byte access are separate grants: `put_bytes()` / `get_bytes()` keep
working even when signing does not, so a download route that falls back to streaming the
bytes itself degrades instead of breaking.

## Local development

`object-storage` is the one backing service that is a cloud bucket rather than a pod, so
locally it stands in as **fake-gcs-server**, which speaks the real GCS API:

```bash
docker compose up -d gcs                              # fake-gcs-server on :4443
export OBJECT_STORAGE_BUCKET=local-dev
export STORAGE_EMULATOR_HOST=http://localhost:4443    # set ONLY locally
```

`storage.py` reads `STORAGE_EMULATOR_HOST` in exactly one place and creates the bucket on
first use, so there is no setup step and **no branch in your own code** — the app you run
locally is byte-for-byte the app you deploy. Full walkthrough: `reference/local-dev.md`.

Three boundaries worth knowing before you trust a green local run:

- The emulator has **no IAM**, so it cannot tell you whether your deployed access is
  correct. It proves your code, not your permissions.
- It does **not verify V4 signatures**, so nothing about signed URLs is really being
  tested — see *Locally, signatures are not real* above.
- Its data is **in memory** — `docker compose restart gcs` empties it. (The helper handles
  the restart; your test fixtures may not.)

## The first write after a first deploy may 403

Granting the app access to a brand-new bucket takes a few seconds to propagate. The
platform waits for the grant before rolling your pods, and `storage.py` retries a `403` a
few times on top of that, so you will rarely see one. **Every** helper goes through that
retry — `put_bytes`, `get_bytes`, `exists`, `list_keys`, `delete`, and both
`download_url()` and `upload_url()` — because the permission to *sign* propagates exactly
like the permission to read, so a first-minute signing 403 has the same cause and the same
answer. (Signing raises a different exception type on the way; see *When signing fails*.)

If you write your own client, add the same **bounded** retry — a few attempts with a short
backoff, then fail. Never an unbounded loop: a permanent 403 is a real problem and it should
surface as one. `storage.py` uses four attempts for object IO and three, with half the
backoff, for signing (see *When signing fails*). And keep the budget in mind wherever you
call from: every one of those attempts is time the caller waits, which is why an `async def`
handler must not make the call inline (see *Every storage call blocks*).

A 403 that persists past the first minute is usually one of two things: calling
`get_bucket()` instead of `bucket()` (see above), or reaching for a bucket that isn't
yours.

## Lifecycle

**The bucket is not part of a deploy.** It is created the first time you declare the
service and then left alone:

| Event | What happens to the files |
|---|---|
| Redeploy, rollback, crash-loop | Nothing. The bucket and its contents are untouched. |
| Removing `object-storage` from `substrait.yaml` | Nothing is deleted. `OBJECT_STORAGE_BUCKET` keeps being injected and the bucket stays yours; the deploy emits a warning so the mismatch is visible. |
| Renaming the app or its organisation | Nothing. The bucket is bound to the app, not to its name. |
| **Deleting the app** | Access is revoked immediately — writes stop working. The files are retained for a grace period (30 days by default) so an operator can still recover them, then the bucket and everything in it are permanently deleted. |

That last row is the only path that destroys data, and it is deliberately slow. A manifest
typo must never be a data-loss event.

## Limits, and what this is not

- **No size quota today.** Writes are never silently dropped or throttled — but nothing
  stops an app filling its bucket either, so cap upload sizes yourself: in your own
  handlers (the example above does) and, for browser-direct uploads, in the signature
  (`max_bytes`).
- **No public buckets, no public objects, no CDN.** Public-read is not available and
  `make_public()` fails by design. Files reach the browser either through your app or as a
  time-limited signed URL — there is no third way, and no permanently public link.
- **Not a backup and not an index.** There is no object versioning; deleted objects are
  soft-deleted for **7 days** as an operator safety net, not as an undo your app can call.
  Record every key you write in your database: the bucket holds bytes, your tables hold
  what they mean.
- **Per-app, not per-tenant.** The platform isolates your app from other apps. Isolating
  *your* tenants from each other is your app's job: prefix keys by tenant and re-validate
  that prefix on every read, write, delete **and sign**.
