#!/usr/bin/env bash
# Slates from the editor — AI-made live documents, decks and interactive pages on the
# Substrait platform (the portal's /slates). Create one from a request, ask it to change,
# pull its HTML to a file, push a hand-edited file back as the next version, and open it.
#
# A slate's page is WRITTEN in one of two places, and an organisation uses ONE of them:
#   on the platform   `new REQUEST` / `ask` — Substrait's AI writes it, on the org's AI key
#   in the editor     the AI in this editor writes the HTML itself (`rules` says what a page
#                     must be) and saves it with the request it was written for:
#                     `new --from FILE --request …` / `put ID FILE --request …`
# Which one is the ORGANISATION's setting, kept on the platform and changed only by the
# platform's administrators — `mode` reads it, and the server refuses the other way.
#
#   list                               my slates, and the ones shared with me (JSON)
#   new --kind doc|deck|page [--title T] [--wait] REQUEST...
#                                      a new slate from one request; the first version is
#                                      written by the AI in the background (--wait follows
#                                      it to the end and prints the result)
#   new --kind doc|deck|page --from FILE [--title T] [--request TEXT [--summary TEXT]]
#                                      a new slate from an HTML document you already have:
#                                      FILE is version 1 as it is, no AI turn runs (the
#                                      title is FILE's <title> unless --title says).
#                                      --request: FILE was just written here for TEXT (the
#                                      person's request) — kept in the slate's history
#                                      with --summary, one line saying what was written
#   show ID                            one slate (JSON: title, kind, head_version, url,
#                                      the turn running on it)
#   ask ID [--attach FILE] [--wait] REQUEST...
#                                      ask the AI to change the slate (202; --wait follows);
#                                      --attach sends FILE with the request — "insert these
#                                      slides" with the slides' HTML, notes to write from
#   history ID                         what was asked, newest first (JSON)
#   versions ID                        the versions (JSON)
#   get ID [--version N] [--out FILE]  the page's HTML — the head, or version N — to
#                                      stdout or FILE (with --out, says which version it
#                                      wrote: the --base a change to it is saved on)
#   put ID FILE [--base N] [--request TEXT [--summary TEXT]]
#                                      save FILE as the next version on top of version N
#                                      (default: the current head). 409 when the slate
#                                      moved on: `get` again and redo the change.
#                                      --request: the change was written here for TEXT —
#                                      kept in the slate's history with --summary (one
#                                      line saying what changed)
#   rules [--kind doc|deck|page]       what a slate's page must be (plain text) — read it
#                                      before writing one here
#   mode                               where this organisation's slates are written:
#                                      `platform` or `editor` (one word). Read it before
#                                      writing; it is not set from here
#   open ID                            print the slate's portal page (and open it)
#   kv ID list                         the slate's store: every key and value (JSON)
#   kv ID get KEY                      one value (JSON)
#   kv ID set KEY JSON                 write one value (JSON text; `set k '"text"'` for a string)
#   kv ID delete KEY                   remove one key
#
# Output is the API's JSON body untouched (the calling agent parses JSON natively; the
# pure-shell _json_field helper can't walk arrays), except `get` (the document) and the
# --wait follow-up (one status line per poll on stderr, the final turn as JSON).
#
# Needs an ACCOUNT credential (personal access token, sbt_): slates belong to a person in
# an org, so an app-scoped deploy token (sbd_) is refused by the server. The profile's
# org (X-Substrait-Org) is the org the slate is created in.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

# Every endpoint here is PAT-gated: resolve the ACCOUNT token and skip the project config
# (a linked folder's sbd_ token would earn a 401 — the library's lesson, B-004).
export SUBSTRAIT_REQUIRE_ACCOUNT=1

die() { echo "Error: $*" >&2; exit 1; }

POLL_S="${SUBSTRAIT_SLATE_POLL_S:-3}"

# _check_auth — explain a 401 in slate terms before dumping the body. A 403 is the
# slate's own answer (a view-only share, not the owner, the permission missing) and its
# detail says so: another login would not change it, so no hint is given there.
_check_auth() {
  case "${SUBSTRAIT_STATUS:-}" in
    401)
      echo "Slates need an ACCOUNT link (personal access token) with the Create slates" >&2
      echo "permission. An app deploy token can't use them — run /substrait:login." >&2
      ;;
  esac
}

# JSON string literals come from substrait-common.sh (substrait_json_str /
# substrait_json_file_str): one escaper for every script.
_is_int() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }

_need_id() { _is_int "${1:-}" || die "usage: $2"; }

# An option that takes a value must have one, or the loop below would never shift.
_need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

_fail() {
  # $1 what failed. Prints the auth hint when apt, then the body, and exits 1.
  _check_auth
  echo "$1 failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
  exit 1
}

# Which editor this copy of the plugin runs in — the name a page written here is recorded
# under (`slate_turns.origin`): the manifest directory says.
_client() {
  if [ -f "$_SUBSTRAIT_PLUGIN_ROOT/.cursor-plugin/plugin.json" ]; then printf 'cursor'
  elif [ -f "$_SUBSTRAIT_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then printf 'claude-code'
  else printf 'editor'
  fi
}

# _request_json REQUEST SUMMARY — the `request` object a page written here is saved with.
_request_json() {
  printf '{"prompt":%s' "$(substrait_json_str "$1")"
  [ -n "$2" ] && printf ',"summary":%s' "$(substrait_json_str "$2")"
  printf ',"client":"%s"}' "$(_client)"
}

# Where this organisation's slates are written — `platform` or `editor`. The setting is
# the organisation's, kept on the platform and changed only by the platform's
# administrators: nothing on this machine holds or overrides it, and the server refuses
# the other way whatever a client sends.
cmd_mode() {
  [ $# -eq 0 ] || die "mode takes no argument: where slates are written is set for the whole organisation by the platform's administrators, not from here. Run \`mode\` to read it."
  substrait_call GET "/api/slates/generation?raw=1" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading where slates are written"
  local place
  place="$(printf '%s' "$SUBSTRAIT_BODY" | tr -d '[:space:]')"
  case "$place" in
    platform) echo "This organisation's slates are written on the platform, by Substrait's AI: use \`new REQUEST\` / \`ask\`." >&2 ;;
    editor)   echo "This organisation's slates are written here in the editor: write the page (see \`rules\`) and save it with \`new --from FILE --request …\` / \`put ID FILE --request …\`." >&2 ;;
    *) die "unexpected answer from the platform: $SUBSTRAIT_BODY" ;;
  esac
  printf '%s\n' "$place"
}

cmd_rules() {
  local kind="doc"
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) _need_value $# --kind; kind="$2"; shift 2 ;;
      doc|deck|page) kind="$1"; shift ;;
      *) die "usage: rules [--kind doc|deck|page]" ;;
    esac
  done
  case "$kind" in doc|deck|page) ;; *) die "--kind must be doc, deck or page" ;; esac
  substrait_call GET "/api/slates/rules?kind=$kind&raw=1" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading the page rules"
  printf '%s\n' "$SUBSTRAIT_BODY"
}

# _follow SLATE_ID TURN_ID — poll the turn until it ends. One line per poll on stderr; the
# final turn's JSON on stdout. Exit 0 for done, 2 otherwise (failed, conflict).
_follow() {
  local sid="$1" tid="$2" status last=""
  while :; do
    substrait_call GET "/api/slates/$sid/turns/$tid" || exit $?
    [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Following turn $tid"
    status="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field status)" || status="?"
    case "$status" in
      done|failed|conflict)
        printf '%s\n' "$SUBSTRAIT_BODY"
        if [ "$status" = "done" ]; then
          echo "Turn $tid done — the slate is at version $(printf '%s' "$SUBSTRAIT_BODY" | _json_field head_version)." >&2
          return 0
        fi
        echo "Turn $tid ended: $status — $(printf '%s' "$SUBSTRAIT_BODY" | _json_field error || echo 'see the body above')" >&2
        return 2 ;;
      *)
        if [ "$status" != "$last" ]; then
          echo "Turn $tid: $status…" >&2
          last="$status"
        fi
        sleep "$POLL_S" ;;
    esac
  done
}

cmd_list() {
  substrait_call GET "/api/slates" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Listing slates"
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_show() {
  _need_id "${1:-}" "show ID"
  substrait_call GET "/api/slates/$1" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading slate $1"
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_history() {
  _need_id "${1:-}" "history ID"
  substrait_call GET "/api/slates/$1/turns" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading the history of slate $1"
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_versions() {
  _need_id "${1:-}" "versions ID"
  substrait_call GET "/api/slates/$1/versions" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading the versions of slate $1"
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_new() {
  local kind="" title="" wait=0 prompt="" from="" request="" summary=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)  _need_value $# --kind; kind="$2"; shift 2 ;;
      --title) _need_value $# --title; title="$2"; shift 2 ;;
      --from)  _need_value $# --from; from="$2"; shift 2 ;;
      --request) _need_value $# --request; request="$2"; shift 2 ;;
      --summary) _need_value $# --summary; summary="$2"; shift 2 ;;
      --wait)  wait=1; shift ;;
      --)      shift; prompt="$*"; break ;;
      -*)      die "unknown option: $1" ;;
      *)       prompt="${prompt:+$prompt }$1"; shift ;;
    esac
  done
  case "$kind" in
    doc|deck|page) ;;
    "") die "say what kind: --kind doc (a document), deck (slides) or page (an interactive tool)" ;;
    *)  die "--kind must be doc, deck or page" ;;
  esac
  if [ -n "$from" ]; then
    _import "$kind" "$title" "$from" "$prompt" "$wait" "$request" "$summary"
    return
  fi
  # No file: the platform writes it, from the request given as the argument.
  [ -z "$request" ] && [ -z "$summary" ] || die "--request and --summary go with --from FILE (a page written here). To have the platform write it: new --kind $kind \"<your request>\""
  [ -n "$prompt" ] || die "say what the slate should be: new --kind $kind \"<your request>\""
  local body
  body="{\"kind\":\"$kind\",\"prompt\":$(substrait_json_str "$prompt")"
  [ -n "$title" ] && body="$body,\"title\":$(substrait_json_str "$title")"
  body="$body}"
  substrait_call POST "/api/slates" -H "Content-Type: application/json" -d "$body" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "201" ] || _fail "Creating the slate"
  local sid tid url
  sid="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field id)" || sid=""
  tid="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field turn_id)" || tid=""
  url="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field url)" || url=""
  printf '%s\n' "$SUBSTRAIT_BODY"
  echo "Created slate $sid ($kind). The AI is writing the first version (turn $tid).${url:+ Open it: $url}" >&2
  if [ "$wait" = 1 ] && [ -n "$sid" ] && [ -n "$tid" ]; then
    _follow "$sid" "$tid"
  fi
}

# `new --from FILE`: the document is version 1 as it is — no AI turn on the platform,
# nothing against the org's daily cap. A bare request alongside it is refused rather than
# silently dropped: it would read as "the platform should change the file", which no turn
# does here (ask for the change afterwards: `ask ID "..."`). `--request TEXT` says something
# else — FILE was WRITTEN here for TEXT — and is recorded with the slate as its first turn.
# --wait has nothing to follow.
_import() {
  local kind="$1" title="$2" file="$3" prompt="$4" wait="$5" request="$6" summary="$7"
  [ -z "$prompt" ] || die "--from imports FILE as it is. If FILE was written here for that request, say so: --request \"<request>\"; to have the platform change it, ask afterwards: ask ID \"<request>\""
  [ "$wait" = 1 ] && die "--wait follows an AI turn; --from runs none (the slate is ready at once)"
  [ -z "$summary" ] || [ -n "$request" ] || die "--summary says what a request changed; give --request too"
  [ -f "$file" ] || die "--from FILE: $file must exist"
  _check_html_file "$file"
  local body
  body="$(mktemp)" || exit 1
  {
    printf '{"kind":"%s"' "$kind"
    [ -n "$title" ] && printf ',"title":%s' "$(substrait_json_str "$title")"
    [ -n "$request" ] && printf ',"request":%s' "$(_request_json "$request" "$summary")"
    printf ',"html":'
    substrait_json_file_str "$file"
    printf '}'
  } > "$body"
  substrait_call POST "/api/slates/import" -H "Content-Type: application/json" \
    --data-binary "@$body" || { rm -f "$body"; exit 1; }
  rm -f "$body"
  [ "${SUBSTRAIT_STATUS:-}" = "201" ] || _fail "Importing $file"
  local sid url
  sid="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field id)" || sid=""
  url="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field url)" || url=""
  printf '%s\n' "$SUBSTRAIT_BODY"
  if [ -n "$request" ]; then
    echo "Created slate $sid ($kind) from $file, written here: version 1, with its request in the history.${url:+ Open it: $url}" >&2
  else
    echo "Imported $file as slate $sid ($kind), version 1.${url:+ Open it: $url}" >&2
  fi
}

cmd_ask() {
  local sid="${1:-}"; shift || true
  _need_id "$sid" "ask ID [--attach FILE] [--wait] REQUEST..."
  local wait=0 prompt="" attach=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait)   wait=1; shift ;;
      --attach) _need_value $# --attach; attach="$2"; shift 2 ;;
      --)       shift; prompt="$*"; break ;;
      -*)       die "unknown option: $1" ;;
      *)        prompt="${prompt:+$prompt }$1"; shift ;;
    esac
  done
  [ -n "$prompt" ] || die "say what should change: ask $sid \"<your request>\""
  if [ -n "$attach" ]; then
    # The file goes with the request as the model's material (any text; an HTML deck's
    # slides, notes) — not as the page: `put` is for that. Streamed to a temp file like
    # `put`'s body, so a multi-megabyte file never sits in a shell variable.
    [ -f "$attach" ] || die "--attach FILE: $attach must exist"
    [ -s "$attach" ] || die "--attach FILE: $attach is empty"
    local body
    body="$(mktemp)" || exit 1
    {
      printf '{"prompt":%s,"attachment":{"name":%s,"text":' \
        "$(substrait_json_str "$prompt")" "$(substrait_json_str "$(basename "$attach")")"
      substrait_json_file_str "$attach"
      printf '}}'
    } > "$body"
    substrait_call POST "/api/slates/$sid/turns" -H "Content-Type: application/json" \
      --data-binary "@$body" || { rm -f "$body"; exit 1; }
    rm -f "$body"
  else
    substrait_call POST "/api/slates/$sid/turns" -H "Content-Type: application/json" \
      -d "{\"prompt\":$(substrait_json_str "$prompt")}" || exit $?
  fi
  [ "${SUBSTRAIT_STATUS:-}" = "202" ] || _fail "Asking slate $sid"
  local tid
  tid="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field id)" || tid=""
  printf '%s\n' "$SUBSTRAIT_BODY"
  echo "Queued turn $tid on slate $sid." >&2
  if [ "$wait" = 1 ] && [ -n "$tid" ]; then
    _follow "$sid" "$tid"
  fi
}

cmd_get() {
  local sid="${1:-}"; shift || true
  _need_id "$sid" "get ID [--version N] [--out FILE]"
  local version="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) _need_value $# --version; version="$2"; shift 2 ;;
      --out)     _need_value $# --out; out="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  local qs="?raw=1"
  if [ -n "$version" ]; then
    _is_int "$version" || die "--version takes a number"
    qs="$qs&version=$version"
  fi
  # The body lands in a file AS IT CAME (SUBSTRAIT_BODY_TO): a shell variable would strip
  # the document's trailing newlines, and `put` of the unchanged file would then be a
  # different document from the head — a spurious version. A temp file first: FILE is
  # replaced only by a 200 body, never by an error page, and never deleted on a failure
  # (an hour of hand edits in it must survive an expired token).
  local tmp
  tmp="$(mktemp)" || exit 1
  SUBSTRAIT_BODY_TO="$tmp" SUBSTRAIT_HEADER_WANT="x-slate-version" \
    substrait_call GET "/api/slates/$sid/content$qs" || { rm -f "$tmp"; exit 1; }
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then rm -f "$tmp"; _fail "Reading slate $sid"; fi
  # Which version these bytes are — the base a change to them is saved on (`put --base`):
  # the head may have moved on by the time the change is ready, and then the save must be
  # refused (409), never laid over somebody else's version.
  local got="${SUBSTRAIT_HEADER:-}"
  _is_int "$got" || got="$version"
  if [ -n "$out" ]; then
    mv -f "$tmp" "$out" 2>/dev/null || { cp -f "$tmp" "$out" && rm -f "$tmp"; } || die "could not write $out"
    echo "Wrote slate $sid${got:+ version $got} to $out.${got:+ Save a change to it with: put $sid $out --base $got}" >&2
  else
    cat "$tmp"      # to stdout the same way: `get ID > f` then `put ID f` is a no-op too
    rm -f "$tmp"
  fi
}

# The server's rule (`slates._DOCTYPE`: ^\s*<!doctype\s+html, case-insensitive), so a
# file is refused here exactly when it would be there — before a multi-MB upload, and
# never for a document the server takes: line breaks are whitespace to it (a newline
# after DOCTYPE, blank lines before it), so they become spaces here rather than vanish;
# the first 4 KB is read, not 64 bytes, for a document that opens with a comment-free
# stretch of whitespace. A BOM fails both. Shared by `put` and `new --from`.
_check_html_file() {
  LC_ALL=C head -c 4096 "$1" | tr '\r\n' '  ' | grep -Eqi '^[[:space:]]*<!doctype[[:space:]]+html' \
    || die "$1 must be one complete HTML document beginning with <!DOCTYPE html>"
}

cmd_put() {
  local sid="${1:-}" file="${2:-}"; shift 2 2>/dev/null || true
  _need_id "$sid" "put ID FILE [--base N] [--request TEXT [--summary TEXT]]"
  [ -n "$file" ] && [ -f "$file" ] || die "usage: put ID FILE [--base N] [--request TEXT [--summary TEXT]] — FILE must exist"
  local base="" request="" summary=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) _need_value $# --base; base="$2"; shift 2 ;;
      --request) _need_value $# --request; request="$2"; shift 2 ;;
      --summary) _need_value $# --summary; summary="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -z "$summary" ] || [ -n "$request" ] || die "--summary says what a request changed; give --request too"
  if [ -z "$base" ]; then
    substrait_call GET "/api/slates/$sid" || exit $?
    [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading slate $sid"
    base="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field head_version)" || die "could not read the slate's head version"
  fi
  _is_int "$base" || die "--base takes a number"
  _check_html_file "$file"
  local body
  body="$(mktemp)" || exit 1
  {
    printf '{"base_version":%s,"source":"editor"' "$base"
    # The page was written here for a request: it is saved with it, and the slate's
    # history gains the turn (the platform runs no model for it).
    [ -n "$request" ] && printf ',"request":%s' "$(_request_json "$request" "$summary")"
    printf ',"html":'
    substrait_json_file_str "$file"
    printf '}'
  } > "$body"
  substrait_call PUT "/api/slates/$sid/content" -H "Content-Type: application/json" \
    --data-binary "@$body" || { rm -f "$body"; exit 1; }
  rm -f "$body"
  if [ "${SUBSTRAIT_STATUS:-}" = "409" ]; then
    echo "The slate moved on since version $base (the body names the head). Run 'get $sid'," >&2
    echo "redo your change on the current page, then put it again." >&2
    printf '%s\n' "$SUBSTRAIT_BODY" >&2
    exit 1
  fi
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Saving slate $sid"
  printf '%s\n' "$SUBSTRAIT_BODY"
  local landed
  landed="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field head_version)"
  if [ "$landed" = "$base" ]; then
    # The server makes no version for a document the head already holds (every source).
    echo "$file is the same document as version $base of slate $sid: nothing to save${request:+ (and no request recorded)}." >&2
  elif [ -n "$request" ]; then
    echo "Saved $file as version $landed of slate $sid, with its request in the history." >&2
  else
    echo "Saved $file as version $landed of slate $sid." >&2
  fi
}

cmd_kv() {
  local sid="${1:-}" op="${2:-}" key="${3:-}"
  _need_id "$sid" "kv ID list|get KEY|set KEY JSON|delete KEY"
  case "$op" in
    list)
      substrait_call GET "/api/slates/$sid/kv" || exit $?
      [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading the store of slate $sid"
      printf '%s\n' "$SUBSTRAIT_BODY" ;;
    get)
      [ -n "$key" ] || die "usage: kv ID get KEY"
      substrait_call GET "/api/slates/$sid/kv/$key" || exit $?
      [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading key '$key' of slate $sid"
      printf '%s\n' "$SUBSTRAIT_BODY" ;;
    set)
      [ -n "$key" ] && [ $# -ge 4 ] || die "usage: kv ID set KEY JSON (the value as JSON text)"
      substrait_call PUT "/api/slates/$sid/kv/$key" -H "Content-Type: application/json" \
        -d "{\"value\":$4}" || exit $?
      [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Writing key '$key' of slate $sid"
      printf '%s\n' "$SUBSTRAIT_BODY" ;;
    delete)
      [ -n "$key" ] || die "usage: kv ID delete KEY"
      substrait_call DELETE "/api/slates/$sid/kv/$key" || exit $?
      [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Deleting key '$key' of slate $sid"
      printf '%s\n' "$SUBSTRAIT_BODY" ;;
    *) die "usage: kv ID list|get KEY|set KEY JSON|delete KEY" ;;
  esac
}

cmd_open() {
  _need_id "${1:-}" "open ID"
  substrait_call GET "/api/slates/$1" || exit $?
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || _fail "Reading slate $1"
  local url
  url="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field url)" || die "the server did not say where the slate's page is"
  printf '%s\n' "$url"
  substrait_open_url "$url" && echo "(opened in your browser)" >&2
  return 0
}

# The header comment, to its end — never the code after it.
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }

case "${1:-}" in
  list)     shift; cmd_list "$@" ;;
  new)      shift; cmd_new "$@" ;;
  show)     shift; cmd_show "$@" ;;
  ask)      shift; cmd_ask "$@" ;;
  history)  shift; cmd_history "$@" ;;
  versions) shift; cmd_versions "$@" ;;
  get)      shift; cmd_get "$@" ;;
  put)      shift; cmd_put "$@" ;;
  open)     shift; cmd_open "$@" ;;
  kv)       shift; cmd_kv "$@" ;;
  rules)    shift; cmd_rules "$@" ;;
  mode)     shift; cmd_mode "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $1 (try: list, new, show, ask, history, versions, get, put, rules, mode, open, kv)" ;;
esac
