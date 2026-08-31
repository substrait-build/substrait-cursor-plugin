---
name: substrait:logs
description: Read the linked Substrait app's runtime logs to debug a live failure
---

You are debugging the **Substrait** app this project is linked to, using the log output
of the pods actually serving it right now.

Use this when the app is DEPLOYED but MISBEHAVING — 500s, a blank page, a request that
hangs. It is not the tool for a failed deploy: while a deploy is still running,
`/substrait:deploy --watch` already streams the build/migration/smoke-test detail. This
command covers the opposite case, where the deploy went green and the app is broken
anyway.

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-logs.sh` under the installed `substrait` Cursor plugin) and run the scripts
from there.

1. **Check the link and the account.** run `bash <plugin>/scripts/substrait-link.sh status`
   Logs need an **account** credential (personal access token), not an app deploy token.
   On a 401 the fix is `/substrait:login`, not `/substrait:link`. You can only read logs
   for an app you own or collaborate on.

2. **Read the backend log** (the default, and where a 500 always originates):
   run `bash <plugin>/scripts/substrait-logs.sh`
   Add `--tail 300` when a traceback is cut off; the maximum is 500.

3. **Read the frontend log** when the page itself is broken — blank, 502, or not
   updating after a deploy:
   run `bash <plugin>/scripts/substrait-logs.sh --component frontend`

4. **Read what comes back carefully.** Every pod for the component is listed, and that
   matters:
   - A pod marked `NOT READY (CrashLoopBackOff)` is the interesting one even when
     another pod is `ready`. A wedged rollout keeps the OLD working pod serving while
     the NEW one crashes, so the app looks alive while the deploy has silently not
     landed. If you see this, say so plainly — the user's latest code is NOT live.
   - `--- previous (terminated) instance ---` means the container is not running now, so
     you are reading the log from just before it died. That is usually where the real
     error is; a crashed container's current log is often empty.
   - `--previous` forces that view for a container that is restarting but currently up.

5. **Diagnose from the actual error, not from the symptom.** Read the traceback to the
   deepest application frame — the file and line inside the app, not inside the
   framework — and go read that source in the repo before proposing a fix. A 500 is
   almost never the framework's fault, and the top of a Python traceback tells you
   nothing about which line was wrong.

6. **Report what you found**, quoting the key lines. If the fix is in this project's
   code, offer to make it and redeploy with `/substrait:deploy`. If the pods are
   healthy and the log shows nothing at the time of the failure, say that rather than
   inventing a cause — the request may not be reaching the app at all.
