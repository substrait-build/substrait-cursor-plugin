---
name: substrait:env
description: View and set the linked Substrait app's environment variables and secrets
---

You are managing the environment variables and secrets of the **Substrait** app this
project is linked to. Edits take effect on the running app within seconds (the platform
reconciles the app's Secret and rolls the backend) — or, if the app isn't deployed yet,
they're stored and injected on the next deploy.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-env.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there.

1. **Check the link:** run `bash <plugin>/scripts/substrait-link.sh status`
   If this project isn't linked, stop and tell the user to run `/substrait:link` first.

2. **Show current config** (also the default when the user gives no specifics):
   run `bash <plugin>/scripts/substrait-env.sh list`
   The output is JSON — present it as a readable table (name, secret or not, value).
   Secret values come back as `null` by design (write-only); show them as `•••• (set)`,
   and never claim to know a secret's current value.

3. **Set a variable:**
   - Plain env var: `bash <plugin>/scripts/substrait-env.sh set NAME "value"`
   - Secret (API keys, credentials — anything that shouldn't be readable later):
     pipe the value on stdin so it stays off the argument list:
     `printf '%s' "the-value" | bash <plugin>/scripts/substrait-env.sh set NAME --secret`
     Stdin also handles multi-line values (PEM keys etc.).
   - When it's ambiguous whether something is a secret, treat it as one — secrets are
     write-only, so err on the safe side. Marking is per-write: re-setting a var flips
     it to whatever you pass this time.
   - `DATABASE_URL`, `JWT_SECRET`, `REDIS_URL`, `KAFKA_BROKERS`, `QDRANT_URL` are
     platform-injected and rejected — don't try to set them; the app already gets them.

4. **Remove a variable:** run `bash <plugin>/scripts/substrait-env.sh unset NAME`

5. **Keep the repo in sync.** If the project declares its config in
   `backend/.env.example` (or a root `.env.example`), add any NEW variable you just
   created there too — placeholder value for env vars, empty value with a trailing
   `# secret` marker for secrets — so future deploys pre-create it. Never write real
   secret values into the repo, and never commit a `.env` with real values.

6. **Report the outcome** — the script says whether the change was applied live or will
   land on the next deploy; relay that. On a 401/403, the fix is `/substrait:link`.

## Deploy environments

Each deploy environment of an app has its **own** variables and secrets. Every command
takes `--env <name>` (e.g. `… substrait-env.sh --env production list`); without it, the
app's default environment — `dev` for an app created in dev, production for an older app.
`$SUBSTRAIT_ENV_TARGET` or an `"environment"` key in `.substrait/config.json` pins one.
A new environment starts from its sibling's non-secret variables (adding `dev` copies
production's; going live copies none); secrets are never copied, so set them per
environment. A **protected** environment (production by
default) accepts variable edits only from the app owner or an admin.
