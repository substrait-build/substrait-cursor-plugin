#!/usr/bin/env bash
# Shared helpers for the Substrait plugin's link/deploy scripts. Sourced, not run —
# so it sets no shell options of its own and never exits the caller.
#
# Two credentials, two config layers:
#   - deploy token (sbd_…): APP-scoped, PER-PROJECT — lives in this project's
#     .substrait/config.json (gitignored), written by `substrait-link.sh login|save`.
#   - personal access token (sbt_…): USER-scoped, held in a PROFILE — one login to one
#     Substrait installation as one org. Profiles live in ~/.substrait/profiles/<name>.json
#     (portal_url, token, org, email), written by `substrait-link.sh account|save-account
#     [--profile NAME] [--org SLUG]`; ~/.substrait/config.json is the ACTIVE profile (the
#     same keys plus "profile": its name), switched by `substrait-link.sh use-profile`.
#     A project using a PAT stores only its app "slug" (sent as X-Substrait-App) and the
#     "profile" it was linked under — no secret. The pin is what keeps a folder deploying
#     to the same installation and org after the machine's active profile changes.
# Resolution order (a project token wins over the account token):
#   portal URL : $SUBSTRAIT_PORTAL_URL  ->  project config  ->  account file
#                                       ->  the plugin's own userConfig (see below)
#   token      : $SUBSTRAIT_TOKEN       ->  project config  ->  account file
#   org        : $SUBSTRAIT_ORG         ->  account file          (sent as X-Substrait-Org)
#   where the ACCOUNT FILE is $SUBSTRAIT_PROFILE's file -> the project's pinned profile
#   -> the active profile (~/.substrait/config.json). A pin naming a profile this machine
#   no longer has is an error, never a silent fall-through to whatever is active.
#
# …EXCEPT for USER-SCOPED surfaces (the library, logs), which the server gates on a PAT
# and refuses an sbd_ token outright. For those, project-first is exactly backwards: a
# builder who has linked an app has a deploy token in the project config, so the
# preference above would send it and earn a 401 no amount of /substrait:login can fix.
# Those callers set SUBSTRAIT_REQUIRE_ACCOUNT=1 (or read substrait_account_token
# directly), which skips the project layer entirely. See B-004.

SUBSTRAIT_CONFIG_FILE="${SUBSTRAIT_CONFIG_FILE:-.substrait/config.json}"
SUBSTRAIT_GLOBAL_CONFIG="${SUBSTRAIT_GLOBAL_CONFIG:-$HOME/.substrait/config.json}"
# One file per saved login (see the profile notes above). Beside the active config, so a
# test or a CI job that relocates one relocates both.
SUBSTRAIT_PROFILES_DIR="${SUBSTRAIT_PROFILES_DIR:-$(dirname "$SUBSTRAIT_GLOBAL_CONFIG")/profiles}"
# The plugin root (this script lives in <root>/scripts/). Used for the userConfig sidecar
# below; self-locating so the same file works unchanged under Claude Code and Cursor.
_SUBSTRAIT_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
# There is NO default portal — the URL is always explicit (multi-tenant: a wrong default
# would silently target the wrong installation). It's supplied once at login/link time via
# --portal-url or $SUBSTRAIT_PORTAL_URL and then stored as portal_url in the config; every
# later command reads it from there.
#
# LAST-RESORT tier: the Claude Code plugin declares a `portal_url` userConfig option, so a
# user can answer it once when installing the plugin instead of passing --portal-url. Claude
# Code exports that answer to HOOK processes as $CLAUDE_PLUGIN_OPTION_PORTAL_URL — not to the
# Bash tool that runs these scripts — so the SessionStart hook mirrors it into the sidecar
# file below and we read that. It ranks BELOW both config files on purpose: an explicit
# login/link is always the stronger signal, and this only fills the gap before one happens.
_SUBSTRAIT_PORTAL_SIDECAR="${_SUBSTRAIT_PLUGIN_ROOT:-.}/.portal-url"

# _json_field KEY — read a JSON object from stdin, print obj[KEY]. Exit 1 if absent.
# Used to pull fields out of API response bodies (the device-link start/poll payloads)
# and config files. Pure shell on purpose: the only guaranteed runtime here is the bash
# that's already executing this script (Git Bash on Windows), so we depend on nothing
# beyond grep/sed/head — no python3 (absent, or a silent App-Execution-Alias stub, on many
# Windows and Node-only dev machines) and no jq. The values we parse are simple and
# server-controlled (tokens, slugs, hostnames, URLs, integers, enum states, run ids) with
# no nested quotes or escapes, so a flat first-match extractor is reliable. Captures stdin
# into a var first so it can make two passes (string value, then number value).
_json_field() {
  local key="$1" body out
  body="$(cat)"
  out="$(printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1)"
  if [ -n "$out" ]; then printf '%s' "$out" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'; return 0; fi
  out="$(printf '%s' "$body" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*-\?[0-9][0-9.eE+-]*" | head -1)"
  if [ -n "$out" ]; then printf '%s' "$out" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*//'; return 0; fi
  return 1
}

# _json_get FILE KEY -> prints the value, or exits 1 if the file or key is absent.
_json_get() { [ -f "$1" ] || return 1; _json_field "$2" < "$1"; }

# substrait_json_str TEXT — TEXT as a JSON string literal, quotes included. Pure awk
# (present wherever bash is, Git Bash included — unlike python3 or jq): backslash, quote,
# tab, CR, newline and form feed escaped, every other C0 control as \u00XX — so a saved
# page is byte for byte the file (NUL excepted: awk cannot carry it). The ONE escaper for
# every request body the scripts build (the library's and the slates' prompts, a saved page).
substrait_json_str() {
  printf '%s' "$1" | _substrait_json_escape_awk
}

# substrait_json_file_str FILE — FILE's content as a JSON string literal (same rules),
# streamed to stdout so a multi-megabyte page never sits in a shell variable. The literal
# ends with \n exactly when FILE does (awk alone cannot tell): `get` writes the body as
# it came, so a `get` → `put` of an unchanged file is byte for byte the head's document —
# which the server answers with the head's number and no new version (services/slates.save).
substrait_json_file_str() {
  local trail=0
  if [ -s "$1" ] && [ -z "$(tail -c 1 "$1")" ]; then trail=1; fi
  _substrait_json_escape_awk "$trail" < "$1"
}

# _substrait_json_escape_awk [TRAIL] — the escaper. Replacement strings are written so
# that gawk (Git Bash, most Linux) and mawk/BSD awk agree: `&&` doubles a backslash (POSIX
# reads a literal `\\` in the replacement as ONE backslash, so "\\\\" would not), and
# `\\&` puts a backslash before the matched quote. TRAIL=1 ends the string with \n.
_substrait_json_escape_awk() {
  awk -v trail="${1:-0}" 'BEGIN { ORS = ""; printf "\"" }
    { gsub(/\\/, "&&"); gsub(/"/, "\\\\&"); gsub(/\t/, "\\t"); gsub(/\r/, "\\r"); gsub(/\f/, "\\f");
      for (c = 1; c <= 31; c++) {
        if (c == 9 || c == 10 || c == 12 || c == 13) continue;
        ch = sprintf("%c", c);
        if (index($0, ch)) gsub(ch, sprintf("\\u%04x", c));
      }
      if (NR > 1) printf "\\n"; printf "%s", $0 }
    END { if (trail == 1 && NR > 0) printf "\\n"; printf "\"" }'
}

# ── Profiles ────────────────────────────────────────────────────────────────────
# substrait_profile_name_ok NAME — a profile name is a file name: letters, digits and
# `.`/`_`/`-`/`@` only, starting with a letter or digit. `@` so the default name of a login
# pinned to an org reads `<org>@<host>`.
substrait_profile_name_ok() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._@-]*$'
}

# substrait_profile_file NAME — where profile NAME is (or would be) stored. A name that
# is not a plain file name (`../x`, a slash) prints nothing and fails: it is spliced into
# a path that is read as a credential and removed on logout, so it is never trusted from
# a flag, an env var or a project config.
substrait_profile_file() {
  substrait_profile_name_ok "$1" || return 1
  printf '%s/%s.json' "$SUBSTRAIT_PROFILES_DIR" "$1"
}

# substrait_project_profile — the profile this folder was linked under (recorded by
# `substrait-link.sh use|create`). Exit 1 when the folder carries no pin.
substrait_project_profile() { _json_get "$SUBSTRAIT_CONFIG_FILE" profile; }

# substrait_active_profile — the name of the ACTIVE profile (~/.substrait/config.json's
# "profile" key). Exit 1 when there is no active config, or it predates profiles (a plain
# portal_url + token file from before 2026-11 — still honoured as the account file).
substrait_active_profile() { _json_get "$SUBSTRAIT_GLOBAL_CONFIG" profile; }

# substrait_legacy_profile — the name the machine's pre-profile login was adopted under
# (`substrait-link.sh` writes it to profiles/.legacy once). Exit 1 when there was none —
# or when that profile has since been logged out of: a name without a file must never be
# written as a folder's pin, which would stop every command there.
substrait_legacy_profile() {
  [ -f "$SUBSTRAIT_PROFILES_DIR/.legacy" ] || return 1
  local v f; v="$(head -1 "$SUBSTRAIT_PROFILES_DIR/.legacy" | tr -d '[:space:]')"
  [ -n "$v" ] && f="$(substrait_profile_file "$v")" && [ -f "$f" ] || return 1
  printf '%s' "$v"
}

# substrait_account_file — the file holding the ACCOUNT credential this command should
# use: $SUBSTRAIT_PROFILE's file (CI / an explicit choice) -> the folder's pinned profile
# -> for an account-linked folder with no pin, the legacy profile (it predates profiles,
# so it was linked under the one login the machine had then) -> the active profile.
# Prints the path, which may not exist (no login yet: callers see _json_get fail exactly
# as before). Returns 1 WITHOUT printing when the requested or pinned profile is one this
# machine does not have — that case must stop the command with a clear message rather
# than quietly run under a different login. substrait_call resolves this once per request
# into _SUBSTRAIT_AF, which short-circuits the readers it then calls.
substrait_account_file() {
  if [ -n "${_SUBSTRAIT_AF:-}" ]; then printf '%s' "$_SUBSTRAIT_AF"; return 0; fi
  local p f
  if [ -n "${SUBSTRAIT_PROFILE:-}" ]; then
    f="$(substrait_profile_file "$SUBSTRAIT_PROFILE")" && [ -f "$f" ] || return 1
    printf '%s' "$f"; return 0
  fi
  if p="$(substrait_project_profile)" && [ -n "$p" ]; then
    f="$(substrait_profile_file "$p")" && [ -f "$f" ] || return 1
    printf '%s' "$f"; return 0
  fi
  if substrait_app_slug >/dev/null 2>&1 && ! _json_get "$SUBSTRAIT_CONFIG_FILE" token >/dev/null 2>&1 \
     && p="$(substrait_legacy_profile)"; then
    substrait_profile_file "$p"; return 0
  fi
  printf '%s' "$SUBSTRAIT_GLOBAL_CONFIG"
}

# substrait_account_profile — the NAME of the profile the account file is (empty for a
# pre-profile config or no login). What status/whoami print, so the name always matches
# the portal and org shown next to it.
substrait_account_profile() {
  local f; f="$(substrait_account_file)" || return 1
  _json_get "$f" profile
}

# substrait_missing_profile_msg — the one wording for "the profile this command needs is
# not on this machine", printed to stderr by the callers of substrait_account_file.
substrait_missing_profile_msg() {
  local p
  if [ -n "${SUBSTRAIT_PROFILE:-}" ]; then p="$SUBSTRAIT_PROFILE"
  else p="$(substrait_project_profile 2>/dev/null)"; fi
  echo "The Substrait profile '$p' is not on this machine — sign in to it with /substrait:login (substrait-link.sh account --profile '$p' --portal-url <URL>), or re-run /substrait:link to bind this project under another profile. Saved profiles: substrait-link.sh profiles." >&2
}

# substrait_org — the org (tenant slug) requests act in: $SUBSTRAIT_ORG, else the account
# file's "org". Empty = no header, so the server uses the user's first membership (what
# every login before profiles did). Lower-cased here, as the server does. An ambient
# $SUBSTRAIT_TOKEN that is NOT the account file's own token (CI) is somebody else's
# credential: a profile's org must not be attached to it — only an explicit
# $SUBSTRAIT_ORG is. (The link script passes the token it read from that very file
# through $SUBSTRAIT_TOKEN, which is why the comparison, not the presence, decides.)
substrait_org() {
  local v f
  if [ -n "${SUBSTRAIT_ORG:-}" ]; then v="$SUBSTRAIT_ORG"
  else
    f="$(substrait_account_file)" || return 1
    if [ -n "${SUBSTRAIT_TOKEN:-}" ] && [ "$SUBSTRAIT_TOKEN" != "$(_json_get "$f" token 2>/dev/null)" ]; then
      return 1
    fi
    v="$(_json_get "$f" org)" || return 1
  fi
  printf '%s' "$v" | tr '[:upper:]' '[:lower:]'
}

# Resolve the portal URL from (in order) the env override, the config the credential in
# use came from, the other config, and finally the plugin's own userConfig answer (env var
# when we happen to inherit it, else the sidecar the SessionStart hook writes). The portal
# FOLLOWS THE CREDENTIAL: a personal token belongs to a profile, so its installation is the
# account file's, and a folder holding an app token for another installation must not
# redirect it; an app token's installation is the project config's. Returns 1 (no output)
# when none is set — there is no default; the caller must surface a "run /substrait:login
# --portal-url <URL>" message. Returns 3 when the account file is a profile this machine
# does not have (the userConfig tiers are NOT consulted then: the folder named its
# installation, and a different one is never the right answer).
substrait_portal_url() {
  local r; r="$(_substrait_portal_lookup)" || return $?
  printf '%s' "${r##*$'\t'}"
}

# _substrait_portal_lookup — the resolution behind substrait_portal_url, printing
# KIND<TAB>FILE<TAB>URL so a caller can also learn WHERE the URL came from:
#   env      $SUBSTRAIT_PORTAL_URL or the userConfig env var (FILE empty)
#   file     a JSON config: a profile file, the active config or the project config
#   sidecar  the one-line userConfig sidecar
# Same return codes as substrait_portal_url (1 = none set, 3 = pinned profile missing).
# _substrait_follow_api_url uses the file to move a stored URL when the server
# announces a new address.
_substrait_portal_lookup() {
  if [ -n "${SUBSTRAIT_PORTAL_URL:-}" ]; then printf 'env\t\t%s' "${SUBSTRAIT_PORTAL_URL%/}"; return 0; fi
  local v f account_first=0
  if [ "${SUBSTRAIT_REQUIRE_ACCOUNT:-}" = "1" ]; then account_first=1
  elif [ -n "${SUBSTRAIT_TOKEN:-}" ]; then case "$SUBSTRAIT_TOKEN" in sbt_*) account_first=1 ;; esac
  elif ! _json_get "$SUBSTRAIT_CONFIG_FILE" token >/dev/null 2>&1; then account_first=1
  fi
  # A missing pinned profile is a hard stop (3) — unless the token itself came from the
  # environment: that override is explicit, and the files are then only a hint.
  if [ "$account_first" -eq 1 ]; then
    if f="$(substrait_account_file)"; then
      if v="$(_json_get "$f" portal_url)"; then printf 'file\t%s\t%s' "$f" "${v%/}"; return 0; fi
    elif [ -z "${SUBSTRAIT_TOKEN:-}" ]; then return 3
    fi
    if v="$(_json_get "$SUBSTRAIT_CONFIG_FILE" portal_url)"; then printf 'file\t%s\t%s' "$SUBSTRAIT_CONFIG_FILE" "${v%/}"; return 0; fi
  else
    if v="$(_json_get "$SUBSTRAIT_CONFIG_FILE" portal_url)"; then printf 'file\t%s\t%s' "$SUBSTRAIT_CONFIG_FILE" "${v%/}"; return 0; fi
    if f="$(substrait_account_file)"; then
      if v="$(_json_get "$f" portal_url)"; then printf 'file\t%s\t%s' "$f" "${v%/}"; return 0; fi
    elif [ -z "${SUBSTRAIT_TOKEN:-}" ]; then return 3
    fi
  fi
  if [ -n "${CLAUDE_PLUGIN_OPTION_PORTAL_URL:-}" ]; then
    printf 'env\t\t%s' "${CLAUDE_PLUGIN_OPTION_PORTAL_URL%/}"; return 0
  fi
  if [ -f "$_SUBSTRAIT_PORTAL_SIDECAR" ]; then
    v="$(head -1 "$_SUBSTRAIT_PORTAL_SIDECAR" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$v" ]; then printf 'sidecar\t%s\t%s' "$_SUBSTRAIT_PORTAL_SIDECAR" "${v%/}"; return 0; fi
  fi
  return 1
}

# ── Following an installation to its new API address (I-268) ─────────────────────
# The server names its canonical API URL on every response (X-Substrait-Api-Url). A
# stored URL that differs is moved in place — same file, same profile name, every
# folder pin intact — after a SUCCESSFUL authenticated call, never on a failure: a 401
# from the wrong installation must not rewrite anything. The old host keeps answering
# while the change runs, so the one command that sees the header is the last that needs
# it. There is no redirect to follow (and none is followed).

# _substrait_header_value FILE NAME — the value of response header NAME from a `curl -D`
# dump (case-insensitive, CR stripped, first match), or exit 1. Pure bash: this runs on
# every substrait_call, and the deploy watcher calls that every few seconds.
_substrait_header_value() {
  local line name="$2" v
  shopt -s nocasematch 2>/dev/null
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == "$name:"* ]] || continue
    v="${line#*:}"; v="${v//$'\r'/}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    shopt -u nocasematch 2>/dev/null
    [ -n "$v" ] && printf '%s' "$v"; return
  done < "$1"
  shopt -u nocasematch 2>/dev/null
  return 1
}

# _substrait_api_url_ok URL — an announced address this script will store: https, a bare
# host (a port is fine), no path. Local development may announce http://localhost.
_substrait_api_url_ok() {
  printf '%s' "$1" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$|^http://(localhost|127\.0\.0\.1)(:[0-9]+)?$'
}

# _substrait_rewrite_portal_url FILE OLD NEW — replace FILE's "portal_url": "OLD" value
# with NEW (a trailing slash on the stored value is tolerated). The file is rewritten in
# place through `cat >`, which keeps its mode (0600) and inode. Exit 1 when FILE does not
# carry OLD — then it is not the file we read the URL from, and it is left alone.
_substrait_rewrite_portal_url() {
  local f="$1" old="$2" new="$3" esc tmp
  esc="$(printf '%s' "$old" | sed 's/[.[\*^$]/\\&/g')"
  grep -q "\"portal_url\"[[:space:]]*:[[:space:]]*\"$esc/\{0,1\}\"" "$f" 2>/dev/null || return 1
  tmp="$(mktemp)" || return 1
  sed "s|\(\"portal_url\"[[:space:]]*:[[:space:]]*\)\"$esc/\{0,1\}\"|\1\"$new\"|" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f"; rm -f "$tmp"
}

# _substrait_follow_api_url OLD NEW — act on an announced address NEW after a call to OLD
# succeeded. Moves the stored URL (see above) and mirrors the move between a profile file
# and the active config when they are the same login. Prints one line to stderr. Never
# fails the caller.
_substrait_follow_api_url() {
  local old="${1%/}" new="${2%/}" r kind rest path cur label prof other pf
  [ -n "$new" ] && [ "$new" != "$old" ] || return 0
  _substrait_api_url_ok "$new" || return 0
  r="$(_substrait_portal_lookup 2>/dev/null)" || return 0
  kind="${r%%$'\t'*}"; rest="${r#*$'\t'}"; path="${rest%%$'\t'*}"; cur="${rest#*$'\t'}"
  # Only the source of the URL we actually used is touched.
  [ "$cur" = "$old" ] || return 0
  case "$kind" in
    env|sidecar)
      # Not ours to rewrite: an env var or CI secret is the operator's, and the sidecar
      # is restored from the plugin's portal URL option by the SessionStart hook at every
      # session start — a rewrite there would be undone, and the real source never named.
      # Said once per process (the deploy watcher calls this every few seconds).
      [ -z "${_SUBSTRAIT_API_MOVE_NOTED:-}" ] || return 0
      _SUBSTRAIT_API_MOVE_NOTED=1
      if [ "$kind" = env ] && [ -n "${SUBSTRAIT_PORTAL_URL:-}" ]; then label='$SUBSTRAIT_PORTAL_URL (or the CI secret behind it)'
      else label="the plugin's portal URL option (set when the plugin was installed)"; fi
      echo "note: this Substrait installation's API is now $new — update $label to it. $old still answers for now." >&2
      return 0 ;;
    file)
      _substrait_rewrite_portal_url "$path" "$old" "$new" || return 0
      if prof="$(_json_get "$path" profile 2>/dev/null)" && [ -n "$prof" ]; then
        label="your profile '$prof'"
        # A profile file and the active config are two copies of one login.
        pf="$(substrait_profile_file "$prof" 2>/dev/null)" || pf=""
        for other in "$pf" "$SUBSTRAIT_GLOBAL_CONFIG"; do
          [ -n "$other" ] && [ "$other" != "$path" ] && [ -f "$other" ] || continue
          [ "$(_json_get "$other" profile 2>/dev/null)" = "$prof" ] || continue
          _substrait_rewrite_portal_url "$other" "$old" "$new" || true
        done
      elif [ "$path" = "$SUBSTRAIT_CONFIG_FILE" ]; then label="this project's link (.substrait/config.json)"
      else label="your saved login ($path)"
      fi ;;
    *) return 0 ;;
  esac
  _SUBSTRAIT_API_MOVE_NOTED=1
  echo "Substrait: this installation's API moved to $new — $label now points there (was $old). Nothing else to do; the next command already uses the new address." >&2
  return 0
}

# substrait_plugin_version — the RELEASE version of the plugin copy running this script,
# read from its own manifest (.claude-plugin/ under Claude Code, .cursor-plugin/ under
# Cursor). Sent on every API call as X-Substrait-Plugin.
#
# The portal uses it for something less obvious than "which build deployed this app": any
# client that sends NOTHING is running a build from before 2026-08-22, i.e. one carrying the
# project-scope update bug (`claude plugin update` silently updates only the user scope). We
# can never ship a fix to those clients — they'd have to update first — so their SILENCE is
# the only signal available, and the portal keys the remediation banner off it.
substrait_plugin_version() {
  local f
  for f in "$_SUBSTRAIT_PLUGIN_ROOT/.claude-plugin/plugin.json" \
           "$_SUBSTRAIT_PLUGIN_ROOT/.cursor-plugin/plugin.json"; do
    [ -f "$f" ] || continue
    _json_get "$f" version && return 0
  done
  return 1
}

# Exit 3 from either token resolver = the account file is a missing profile.
substrait_token() {
  if [ "${SUBSTRAIT_REQUIRE_ACCOUNT:-}" = "1" ]; then substrait_account_token; return $?; fi
  if [ -n "${SUBSTRAIT_TOKEN:-}" ]; then printf '%s' "$SUBSTRAIT_TOKEN"; return 0; fi
  if _json_get "$SUBSTRAIT_CONFIG_FILE" token; then return 0; fi
  local f; f="$(substrait_account_file)" || return 3
  _json_get "$f" token
}

# substrait_account_token — the ACCOUNT credential (sbt_) only, skipping the project
# config. For endpoints the server gates on a PAT: sending the project's sbd_ token
# there is a guaranteed 401, and it is the DEFAULT resolution in any linked project,
# which is what made /substrait:library unusable for linked apps (B-004).
#
# $SUBSTRAIT_TOKEN still wins when it is an account token — an explicit override should
# work here too — but an sbd_ value in it is ignored rather than sent to certain failure.
substrait_account_token() {
  case "${SUBSTRAIT_TOKEN:-}" in
    sbt_*) printf '%s' "$SUBSTRAIT_TOKEN"; return 0 ;;
  esac
  local f; f="$(substrait_account_file)" || return 3
  _json_get "$f" token
}

# substrait_app_slug — the app this project is bound to (cached by link). With a
# personal (sbt_) token this is what NAMES the target app; with an app (sbd_) token
# it's display-only (the server infers the app from the token).
substrait_app_slug() { _json_get "$SUBSTRAIT_CONFIG_FILE" slug; }

# substrait_env_target — which DEPLOY ENVIRONMENT of the app a command means (Substrait
# environments: production and/or dev). Resolution: the --env flag (the scripts
# export it as $SUBSTRAIT_ENV_TARGET, which can also be set directly) -> an "environment"
# key in the project config (.substrait/config.json; add it by hand to pin a folder to an
# environment — the link script preserves it). Empty = no header, so the server picks the
# app's DEFAULT environment: `dev` for an app created in dev, production for an app
# created before apps started there. Lower-cased here, as the server does. Sent as
# X-Substrait-Env on /api/deploy/*. NOT $SUBSTRAIT_ENV: that name is the app's injected
# runtime variable (production|preview) and the platform's own prod|demo deploy switch.
substrait_env_target() {
  local v
  if [ -n "${SUBSTRAIT_ENV_TARGET:-}" ]; then v="$SUBSTRAIT_ENV_TARGET"
  else v="$(_json_get "$SUBSTRAIT_CONFIG_FILE" environment)" || return 1
  fi
  printf '%s' "$v" | tr '[:upper:]' '[:lower:]'
}

# substrait_call METHOD PATH [extra curl args...]
# Performs the request and sets two globals in the CURRENT shell:
#   SUBSTRAIT_BODY    — the response body
#   SUBSTRAIT_STATUS  — the HTTP status code
# Returns 2 if unconfigured, else curl's exit code.
#
# IMPORTANT: call this as a plain statement, e.g.
#       substrait_call GET /api/deploy/app || exit $?
# NEVER inside a command substitution ( x="$(substrait_call ...)" ) — that runs it in a
# subshell, so the globals it sets would not reach the caller. (That was the original bug.)
substrait_call() {
  # Resolve the account file ONCE for the portal, token and org readers below: the deploy
  # watcher calls this every few seconds for the length of a build, and each reader would
  # otherwise re-derive it (a few forks each time). Empty = unresolvable; the readers then
  # report exit 3 themselves.
  _SUBSTRAIT_AF="$(substrait_account_file 2>/dev/null)" || _SUBSTRAIT_AF=""
  _substrait_call_resolved "$@"
  local rc=$?
  unset _SUBSTRAIT_AF
  return $rc
}

_substrait_call_resolved() {
  local method="$1" path="$2"; shift 2
  local base token tmp slug org rc
  base="$(substrait_portal_url)" || {
    rc=$?
    if [ "$rc" -eq 3 ]; then substrait_missing_profile_msg; return 2; fi
    echo "No portal URL configured — run /substrait:login --portal-url <your Substrait API URL> (there is no default; you can also set it once as the plugin's 'Substrait portal URL' option)." >&2; return 2; }
  token="$(substrait_token)" || {
    rc=$?
    if [ "$rc" -eq 3 ]; then substrait_missing_profile_msg; return 2; fi
    if [ "${SUBSTRAIT_REQUIRE_ACCOUNT:-}" = "1" ]; then
      echo "This needs an ACCOUNT link — run /substrait:login. (A project deploy token" >&2
      echo "can't be used here; it only authorizes deploys of its own app.)" >&2
    else
      echo "No token configured — run /substrait:link." >&2
    fi
    return 2; }
  # A personal token authenticates the USER; the target app must be named explicitly.
  # /api/deploy/* reads it from X-Substrait-App (the slug `link use` cached). Other
  # endpoints (e.g. /api/projects) ignore the extra header, so it's always safe to send.
  if [ "${token#sbt_}" != "$token" ]; then
    if slug="$(substrait_app_slug)" && [ -n "$slug" ]; then
      set -- -H "X-Substrait-App: $slug" "$@"
    elif [ "${path#/api/deploy}" != "$path" ]; then
      echo "This project isn't bound to an app yet — run /substrait:link to pick one." >&2
      return 2
    fi
    # The org (tenant) the person acts in. A personal token spans every org its user
    # belongs to, and the server defaults to the first membership; the profile's org makes
    # the choice explicit, which is also what disambiguates a slug that exists in two orgs.
    if org="$(substrait_org)" && [ -n "$org" ]; then
      set -- -H "X-Substrait-Org: $org" "$@"
    fi
  fi
  # The deploy environment this command targets (see substrait_env_target). Only the
  # /api/deploy/* routes read it; elsewhere it is ignored.
  local env_target
  if env_target="$(substrait_env_target)" && [ -n "$env_target" ]; then
    set -- -H "X-Substrait-Env: $env_target" "$@"
  fi
  # Identify the plugin build. Harmless on every endpoint; the portal reads it on deploy.
  local pv
  if pv="$(substrait_plugin_version)" && [ -n "$pv" ]; then
    set -- -H "X-Substrait-Plugin: $pv" "$@"
  fi
  tmp="$(mktemp)" || return 1
  local hdr; hdr="$(mktemp)" || { rm -f "$tmp"; return 1; }
  SUBSTRAIT_STATUS="$(curl -sS -o "$tmp" -D "$hdr" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer $token" "$base$path" "$@" 2>/dev/null)"
  local rc=$?
  # SUBSTRAIT_BODY_TO=FILE (set by the caller for THIS call) keeps the body byte for byte
  # in FILE: a shell variable strips trailing newlines and NULs, which is fine for JSON
  # and wrong for a document that must round-trip (a slate's HTML). A 2xx body is then
  # NOT copied into SUBSTRAIT_BODY — it may be megabytes the caller reads from the file;
  # an error body still is, so the caller can say what went wrong.
  if [ -z "${SUBSTRAIT_BODY_TO:-}" ]; then
    SUBSTRAIT_BODY="$(cat "$tmp")"
  else
    case "${SUBSTRAIT_STATUS:-}" in 2*) SUBSTRAIT_BODY="" ;; *) SUBSTRAIT_BODY="$(cat "$tmp")" ;; esac
    mv -f "$tmp" "$SUBSTRAIT_BODY_TO" 2>/dev/null || cp -f "$tmp" "$SUBSTRAIT_BODY_TO"
  fi
  rm -f "$tmp"
  # The installation announced its canonical address: follow it, but only on success —
  # a 401/403 may well be the WRONG installation answering (I-268).
  local announced=""
  case "${SUBSTRAIT_STATUS:-}" in 2*) announced="$(_substrait_header_value "$hdr" x-substrait-api-url)" || announced="" ;; esac
  rm -f "$hdr"
  [ -z "$announced" ] || _substrait_follow_api_url "$base" "$announced"
  # 426 Upgrade Required: this plugin release is below the installation's minimum. The
  # server's detail says exactly what to run; say it once per process, before whatever
  # the caller prints about its own failed request.
  if [ "${SUBSTRAIT_STATUS:-}" = "426" ] && [ -z "${_SUBSTRAIT_UPGRADE_NOTED:-}" ]; then
    _SUBSTRAIT_UPGRADE_NOTED=1
    local why; why="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail)" || why="this plugin release is below the minimum the installation accepts"
    echo "Substrait: UPDATE REQUIRED — $why" >&2
  fi
  return $rc
}

# substrait_anon_call METHOD URL [extra curl args...]
# An UNAUTHENTICATED request to an absolute URL — used by the browser device-link flow
# (start/poll carry no token; the token is what the flow is fetching). Sets the same
# SUBSTRAIT_BODY / SUBSTRAIT_STATUS globals as substrait_call (so don't call it inside a
# command substitution). Returns curl's exit code.
# Also sets SUBSTRAIT_API_URL_ANNOUNCED to the address the server announced on a 2xx
# (X-Substrait-Api-Url; empty otherwise), so a login saves the installation's CURRENT
# address rather than the one the person typed (I-268).
substrait_anon_call() {
  local method="$1" url="$2"; shift 2
  local tmp; tmp="$(mktemp)" || return 1
  local hdr; hdr="$(mktemp)" || { rm -f "$tmp"; return 1; }
  SUBSTRAIT_STATUS="$(curl -sS -o "$tmp" -D "$hdr" -w '%{http_code}' -X "$method" "$url" "$@" 2>/dev/null)"
  local rc=$?
  # SUBSTRAIT_BODY_TO=FILE (set by the caller for THIS call) keeps the body byte for byte
  # in FILE: a shell variable strips trailing newlines and NULs, which is fine for JSON
  # and wrong for a document that must round-trip (a slate's HTML). A 2xx body is then
  # NOT copied into SUBSTRAIT_BODY — it may be megabytes the caller reads from the file;
  # an error body still is, so the caller can say what went wrong.
  if [ -z "${SUBSTRAIT_BODY_TO:-}" ]; then
    SUBSTRAIT_BODY="$(cat "$tmp")"
  else
    case "${SUBSTRAIT_STATUS:-}" in 2*) SUBSTRAIT_BODY="" ;; *) SUBSTRAIT_BODY="$(cat "$tmp")" ;; esac
    mv -f "$tmp" "$SUBSTRAIT_BODY_TO" 2>/dev/null || cp -f "$tmp" "$SUBSTRAIT_BODY_TO"
  fi
  rm -f "$tmp"
  SUBSTRAIT_API_URL_ANNOUNCED=""
  case "${SUBSTRAIT_STATUS:-}" in
    2*) SUBSTRAIT_API_URL_ANNOUNCED="$(_substrait_header_value "$hdr" x-substrait-api-url)" || SUBSTRAIT_API_URL_ANNOUNCED="" ;;
  esac
  rm -f "$hdr"
  return $rc
}

# _json_str_array KEY — read a JSON object from stdin, print obj[KEY] (a flat array of
# simple strings, e.g. ["semgrep","trivy"]) as one comma-separated line ("semgrep,trivy").
# Empty output for an empty array; exit 1 if the key is absent. Same flat first-match
# contract as _json_field: the values are server-controlled slugs with no quotes, commas
# or brackets inside them.
_json_str_array() {
  local key="$1" out
  out="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | head -1)"
  [ -n "$out" ] || return 1
  printf '%s' "$out" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*\[//; s/\]$//' | tr -d '" '
}

# ── What a deploy ships: the ONE exclude list ───────────────────────────────────
# The source-only zip (substrait-deploy.sh `package`, zip AND its tar fallback) and the
# local source fingerprint (substrait_source_fingerprint, compared by /substrait:fix
# against the one the server stored for the deployed zip) must agree on which files a
# deploy carries — otherwise the two hashes differ for a reason that is not the source.
# So the list lives here once, and three generators render it in each tool's syntax.
# Never copy these names into another script: add to the list instead.
#
#   SUBSTRAIT_EXCLUDE_DIRS       directories skipped at ANY depth
#   SUBSTRAIT_EXCLUDE_ROOT_DIRS  directories skipped only at the project root
#   SUBSTRAIT_EXCLUDE_FILES      file-name globs skipped at any depth
#
# Directories match directories only: a FILE named .git (a worktree / submodule pointer)
# is not excluded — zip's `.git/*` pattern never matched one, and the fingerprint follows
# the zip. Space-separated words; globbing is switched off while they are split.
SUBSTRAIT_EXCLUDE_DIRS=".git node_modules .venv venv __pycache__ dist build"
SUBSTRAIT_EXCLUDE_ROOT_DIRS=".substrait"
SUBSTRAIT_EXCLUDE_FILES="*.pyc .DS_Store"

# The generators fill the global array SUBSTRAIT_EXCLUDE_ARGS (bash 3.2 has no way to
# return an array, and printing words would need an eval to re-split them safely). Use it
# straight after the call:  substrait_zip_exclude_args; zip -rq out.zip . -x "${SUBSTRAIT_EXCLUDE_ARGS[@]}"

# _substrait_words "LIST" — print each space-separated word of LIST on its own line with
# pathname expansion off, so "*.pyc" stays a pattern instead of matching files in the CWD.
_substrait_words() {
  local w noglob=0
  case $- in *f*) noglob=1 ;; esac
  set -f
  for w in $1; do printf '%s\n' "$w"; done
  [ "$noglob" -eq 1 ] || set +f
}

# substrait_zip_exclude_args — `zip -x` patterns. zip matches each pattern against the
# whole stored path and its `*` also matches "/", so "X/*" is X at the root and "*/X/*" is
# X anywhere below it.
substrait_zip_exclude_args() {
  local w
  SUBSTRAIT_EXCLUDE_ARGS=()
  while IFS= read -r w; do [ -n "$w" ] && SUBSTRAIT_EXCLUDE_ARGS+=("$w/*" "*/$w/*"); done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_DIRS")
EOF
  while IFS= read -r w; do [ -n "$w" ] && SUBSTRAIT_EXCLUDE_ARGS+=("$w/*"); done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_ROOT_DIRS")
EOF
  while IFS= read -r w; do [ -n "$w" ] && SUBSTRAIT_EXCLUDE_ARGS+=("$w" "*/$w"); done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_FILES")
EOF
}

# substrait_tar_exclude_args — `tar --exclude=` options for the Windows fallback, which
# archives "." so member names start with "./".
substrait_tar_exclude_args() {
  local w
  SUBSTRAIT_EXCLUDE_ARGS=()
  while IFS= read -r w; do [ -n "$w" ] && SUBSTRAIT_EXCLUDE_ARGS+=("--exclude=./$w" "--exclude=*/$w"); done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_DIRS")
EOF
  while IFS= read -r w; do [ -n "$w" ] && SUBSTRAIT_EXCLUDE_ARGS+=("--exclude=./$w"); done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_ROOT_DIRS")
EOF
  while IFS= read -r w; do [ -n "$w" ] && SUBSTRAIT_EXCLUDE_ARGS+=("--exclude=$w"); done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_FILES")
EOF
}

# substrait_find_prune_expr — a complete `find -L . <expr>` expression that prints every
# regular file a deploy would ship ("./path" form), pruning the excluded directories.
substrait_find_prune_expr() {
  local w first=1
  SUBSTRAIT_EXCLUDE_ARGS=(-type d "(")
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$first" -eq 1 ] || SUBSTRAIT_EXCLUDE_ARGS+=(-o); first=0
    SUBSTRAIT_EXCLUDE_ARGS+=(-name "$w")
  done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_DIRS")
EOF
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$first" -eq 1 ] || SUBSTRAIT_EXCLUDE_ARGS+=(-o); first=0
    SUBSTRAIT_EXCLUDE_ARGS+=(-path "./$w")
  done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_ROOT_DIRS")
EOF
  SUBSTRAIT_EXCLUDE_ARGS+=(")" -prune -o -type f "!" "(")
  first=1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$first" -eq 1 ] || SUBSTRAIT_EXCLUDE_ARGS+=(-o); first=0
    SUBSTRAIT_EXCLUDE_ARGS+=(-name "$w")
  done <<EOF
$(_substrait_words "$SUBSTRAIT_EXCLUDE_FILES")
EOF
  SUBSTRAIT_EXCLUDE_ARGS+=(")" -print)
}

# ── Hashing ─────────────────────────────────────────────────────────────────────
# Portable sha256: sha256sum (Linux, Git Bash, recent macOS) -> shasum -a 256 (macOS,
# Perl) -> openssl. Each reads stdin, so no tool ever sees (or escapes) a file name.
# $SUBSTRAIT_SHA256_TOOL (sha256sum|shasum|openssl) forces one — the fingerprint test uses
# it to prove all three agree.
_substrait_sha256_tool() {
  case "${SUBSTRAIT_SHA256_TOOL:-}" in
    sha256sum|shasum|openssl)
      if command -v "$SUBSTRAIT_SHA256_TOOL" >/dev/null 2>&1; then echo "$SUBSTRAIT_SHA256_TOOL"; return 0; fi
      echo "SUBSTRAIT_SHA256_TOOL=$SUBSTRAIT_SHA256_TOOL is not installed." >&2; return 2 ;;
  esac
  if command -v sha256sum >/dev/null 2>&1; then echo sha256sum
  elif command -v shasum >/dev/null 2>&1; then echo shasum
  elif command -v openssl >/dev/null 2>&1; then echo openssl
  else
    echo "No sha256 tool found — install coreutils (sha256sum), Perl's shasum, or openssl." >&2
    return 2
  fi
}

# substrait_sha256_stdin — print the sha256 hex of stdin (the hex only). Returns 2 when
# no sha256 tool exists.
substrait_sha256_stdin() {
  local tool out
  tool="${_SUBSTRAIT_SHA_TOOL:-}"
  [ -n "$tool" ] || tool="$(_substrait_sha256_tool)" || return 2
  case "$tool" in
    sha256sum) out="$(sha256sum)" ;;
    shasum)    out="$(shasum -a 256)" ;;
    openssl)   out="$(openssl dgst -sha256 -r)" ;;
  esac || return 1
  out="${out%% *}"
  # Some builds prefix a "\" when they escaped a name; stdin has none, but be exact.
  printf '%s\n' "${out#\\}"
}

# substrait_sha256_file FILE — print the sha256 hex of FILE.
substrait_sha256_file() { substrait_sha256_stdin < "$1"; }

# substrait_source_fingerprint DIR — the SOURCE FINGERPRINT of the files a deploy of DIR
# would ship right now, exactly as the server computes it for an accepted upload: for
# every regular file (after the exclude list above), the line "<sha256 hex>  <path>\n"
# with the path relative to DIR and "/"-separated; lines sorted bytewise by path
# (LC_ALL=C); the fingerprint is the sha256 hex of their concatenation. Symlinks are
# followed (`find -L`), as `zip -r` stores what a link points at — the server never sees
# a link in a plugin-built zip. Paths containing a newline are unsupported (as in zip).
# Mtimes, permissions and the zip's own bytes do not matter: the same tree deployed from
# the portal button or another machine gives the same value. Returns 2 when no sha256
# tool exists, 1 on any other failure — never prints a partial value.
substrait_source_fingerprint() {
  local dir="${1:-.}" lines rc
  _SUBSTRAIT_SHA_TOOL="$(_substrait_sha256_tool)" || return 2
  [ -d "$dir" ] || { echo "not a directory: $dir" >&2; return 1; }
  lines="$(
    cd "$dir" || exit 1
    substrait_find_prune_expr
    find -L . "${SUBSTRAIT_EXCLUDE_ARGS[@]}" | LC_ALL=C sort | while IFS= read -r p; do
      h="$(substrait_sha256_file "$p")" || exit 1
      printf '%s  %s\n' "$h" "${p#./}"
    done
  )"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  # $( ) dropped the final newline; every line (the last included) ends in one.
  if [ -n "$lines" ]; then printf '%s\n' "$lines" | substrait_sha256_stdin
  else printf '' | substrait_sha256_stdin
  fi
}

# ── Deploy-contract compliance ──────────────────────────────────────────────────
# substrait_compliance_check — audit the CWD (run from the project root) against the
# cheap, high-value, statically-checkable parts of the deploy contract. This MIRRORS
# the server's authoritative check (`infra.validate_app`); the server still runs the
# full (incl. behavioural) validation in VALIDATING — this exists so the common
# failures become actionable local errors instead of a failed remote run.
# Prints one "✗ …" line per violation (each with its fix) to stdout and returns the
# number of violations, so callers can gate (deploy preflight), report everything at
# once (init / `deploy check`), or both. Read-only: mutates nothing.
substrait_compliance_check() {
  local fails=0 f backend_df="" frontend_df=""
  # Backend Dockerfile: cicd/Dockerfile.backend, cicd/Dockerfile, or backend/Dockerfile.
  for f in cicd/Dockerfile.backend cicd/Dockerfile backend/Dockerfile; do
    if [ -f "$f" ]; then backend_df="$f"; break; fi
  done
  if [ -z "$backend_df" ]; then
    echo "✗ no backend Dockerfile — every app must ship one of cicd/Dockerfile.backend, cicd/Dockerfile or backend/Dockerfile (start from the scaffold's cicd/Dockerfile.backend). It must EXPOSE 8000, serve GET /health, and your API under /api."
    fails=$((fails+1))
  fi
  # Frontend Dockerfile is required only when a frontend/ is shipped.
  if [ -d frontend ]; then
    for f in cicd/Dockerfile.frontend frontend/Dockerfile; do
      if [ -f "$f" ]; then frontend_df="$f"; break; fi
    done
    if [ -z "$frontend_df" ]; then
      echo "✗ frontend/ is present but ships no Dockerfile — add one of cicd/Dockerfile.frontend or frontend/Dockerfile (start from the scaffold's cicd/Dockerfile.frontend). It must serve the built site on port 80."
      fails=$((fails+1))
    fi
  fi
  # substrait.yaml is REQUIRED, with a real (non-placeholder) description.
  if [ ! -f substrait.yaml ]; then
    echo "✗ no substrait.yaml at the project root — every app ships one with a \`description:\` (what the app does and who it's for; shown in the portal and the API Library) plus any backing services it uses (redis/kafka/qdrant/object-storage) under \`services:\` — omitting a declared service removes it."
    fails=$((fails+1))
  elif ! grep -Eq '^[[:space:]]*description[[:space:]]*:' substrait.yaml; then
    echo "✗ substrait.yaml has no \`description:\` — add one to three sentences on what the app does and who it's for."
    fails=$((fails+1))
  elif grep -q 'Describe your app here' substrait.yaml; then
    echo "✗ substrait.yaml still carries the scaffold placeholder description — replace it with what this app actually does."
    fails=$((fails+1))
  fi
  # The database is explicit: Flyway migrations without a `database:` engine in the
  # manifest fail server-side VALIDATING (the DB is only provisioned when declared),
  # so mirror it here. Checked only when a manifest exists — the missing-manifest
  # violation above already covers the rest.
  if [ -f substrait.yaml ] \
     && ! grep -Eq '^[[:space:]]*database[[:space:]]*:' substrait.yaml; then
    local mig_dir
    for mig_dir in backend/resources/db/migration resources/db/migration; do
      if [ -d "$mig_dir" ] && ls "$mig_dir"/*.sql >/dev/null 2>&1; then
        echo "✗ the app ships Flyway migrations ($mig_dir/) but substrait.yaml declares no \`database:\` — the platform provisions the database (and injects DATABASE_URL) only when declared. Add \`database: oceanbase\` (the default; or \`postgres\`/\`mysql\` for the app's own single-node pod) to substrait.yaml, or remove the migrations if the app truly uses no database."
        fails=$((fails+1))
        break
      fi
    done
  fi
  # k8s/ is platform-owned and must not be shipped.
  if [ -d k8s ]; then
    echo "✗ a k8s/ directory is present — the platform owns the Kubernetes manifests and discards anything you ship there. Remove k8s/."
    fails=$((fails+1))
  fi
  return $fails
}

# ── Project memory (CLAUDE.md) ──────────────────────────────────────────────────
# The plugin maintains a marker-delimited "Substrait deployment" block in the
# project's agent-memory file, so every future session in the project knows the
# deploy contract without the skill being invoked. The block's CONTENT is the
# bundled skill's reference/claude-md-snippet.md (canonical, synced from the
# monorepo — including its BEGIN/END markers and version tag); this helper only
# places it. Target file defaults to CLAUDE.md; Cursor invocations override via
# SUBSTRAIT_MEMO_FILE=AGENTS.md.
_SUBSTRAIT_SNIPPET="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../skills/substrait-app/reference/claude-md-snippet.md"

# substrait_write_memo MODE
#   ensure  — add the block (creating the file if needed) or refresh an outdated one.
#             Used by link: linking is the moment a project becomes a Substrait project.
#   refresh — only update an EXISTING outdated block; never (re-)add one. Used by
#             deploy, so deleting the block is a durable opt-out.
# The snippet is a template: __SUBSTRAIT_APP_LINK__ is filled from the project config
# (slug/host cached by link), so the block names the app it deploys to. Update
# detection compares the RENDERED block to what's in the file — that covers both a
# snippet version bump and a relink to a different app, with no mtime churn when
# current. Always returns 0: memo maintenance must never fail a link/deploy.
substrait_write_memo() {
  local mode="$1" target="${SUBSTRAIT_MEMO_FILE:-CLAUDE.md}"
  [ -f "$_SUBSTRAIT_SNIPPET" ] || return 0
  local begin='<!-- BEGIN substrait-app contract'
  local slug host app
  slug="$(_json_get "$SUBSTRAIT_CONFIG_FILE" slug 2>/dev/null)" || slug=""
  host="$(_json_get "$SUBSTRAIT_CONFIG_FILE" host 2>/dev/null)" || host=""
  app="\`${slug:-unknown}\`${host:+ — https://$host}"
  local rendered; rendered="$(mktemp)" || return 0
  sed "s|__SUBSTRAIT_APP_LINK__|$app|" "$_SUBSTRAIT_SNIPPET" > "$rendered"
  if [ -f "$target" ] && grep -qF "$begin" "$target"; then
    local current
    current="$(awk 'index($0, "<!-- BEGIN substrait-app contract") {inb=1}
                    inb {print}
                    index($0, "<!-- END substrait-app contract") {inb=0}' "$target")"
    if [ "$current" = "$(cat "$rendered")" ]; then rm -f "$rendered"; return 0; fi
    local tmp; tmp="$(mktemp)" || { rm -f "$rendered"; return 0; }
    awk -v s="$rendered" '
      index($0, "<!-- BEGIN substrait-app contract") {
        inblock=1
        while ((getline line < s) > 0) print line
        close(s); next
      }
      index($0, "<!-- END substrait-app contract") { inblock=0; next }
      !inblock { print }
    ' "$target" > "$tmp" && mv "$tmp" "$target" && \
      echo "Updated the Substrait section in $target."
  else
    if [ "$mode" = "refresh" ]; then rm -f "$rendered"; return 0; fi
    { [ -s "$target" ] && printf '\n'; cat "$rendered"; } >> "$target" && \
      echo "Recorded the Substrait deploy contract in $target (so future sessions know this is a Substrait app)."
  fi
  rm -f "$rendered"
  return 0
}

# substrait_open_url URL — best-effort open in the user's browser; silent if no opener.
#
# Windows (B-001): Claude Code and Cursor run these scripts in Git Bash (MINGW/MSYS) or
# Cygwin, where there is no `open`/`xdg-open`. `explorer.exe URL` is NOT a browser opener
# there: given anything it doesn't parse as a URL it opens File Explorer, and it exits 1
# even when it worked — so "(opened in your browser)" never printed and the agent retried
# another way. `rundll32 url.dll,FileProtocolHandler` hands the URL to the default browser
# (what Go's and Python's webbrowser openers use); MSYS path conversion is switched off
# for the call so the URL reaches it untouched. Only http(s) URLs are ever opened — a
# bare path must never reach an opener that would show a folder instead.
substrait_open_url() {
  case "$1" in http://*|https://*) ;; *) return 1 ;; esac
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        rundll32.exe url.dll,FileProtocolHandler "$1" >/dev/null 2>&1
      return $? ;;
  esac
  if command -v open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1   # macOS
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1  # Linux
  elif command -v wslview >/dev/null 2>&1; then wslview "$1" >/dev/null 2>&1  # WSL (wslu)
  elif command -v explorer.exe >/dev/null 2>&1; then
    # WSL without wslu: explorer.exe opens the URL but exits 1 even on success.
    explorer.exe "$1" >/dev/null 2>&1; return 0
  else return 1; fi
}
