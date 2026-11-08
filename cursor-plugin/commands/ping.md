---
name: substrait:ping
description: Check the plugin and every saved Substrait login — confirms the installed version and moves a login to its installation's new address
---

The bundled scripts live in this plugin's `scripts/` directory. Resolve the plugin root
(if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the directory containing
`substrait-link.sh` under the installed `substrait` Cursor plugin), then run exactly this,
once, and nothing else:

`bash <plugin>/scripts/substrait-link.sh ping`

It prints the plugin's release version, then one line per saved login (and one for this
folder's own app link, if it has one). It only READS from Substrait, but when an
installation has moved to a new address, a successful check rewrites that login's saved
address to the new one — that is expected, and the script says so.

Reply with the script's output as is: the version line, each login's line, and any
"API moved to …" line. If a login failed (HTTP 401, unreachable, no portal URL), add one
short sentence with the fix the line names (usually `/substrait:login`). Do not run any
other command, and do not edit any file yourself.
