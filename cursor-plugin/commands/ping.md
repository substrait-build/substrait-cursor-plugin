---
name: substrait:ping
description: No-op test command — confirms the installed plugin version (used to verify plugin updates take effect)
---

This is a deliberate no-op used to verify that a plugin update has taken effect. Do
**not** run any scripts, make any network calls, or modify any files.

Resolve the plugin root (if `$CURSOR_PLUGIN_ROOT` is set, use it; otherwise locate the
installed `substrait` Cursor plugin directory) and read the `"version"` field from its
`.cursor-plugin/plugin.json`, then reply with exactly one short line:

> Substrait plugin is alive — release version `<version>`.

Nothing else.
