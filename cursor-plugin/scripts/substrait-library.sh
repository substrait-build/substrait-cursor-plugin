#!/usr/bin/env bash
# Browse the Substrait API Library — the design-time catalog of APIs an app can be
# built against: `internal` entries (admin-registered company API specs) and `app`
# entries (deployed Substrait apps' endpoint inventories).
#
#   list [--q TERM] [--tag TAG]      the whole catalog (JSON, printed verbatim)
#   show KIND SLUG                   one entry's detail (KIND = internal|app);
#                                    includes its endpoint summary + auth notes
#   spec [KIND] SLUG [--out FILE]    an entry's full OpenAPI document (KIND =
#                                    internal|app, default internal); app specs
#                                    come from the platform's post-deploy harvest,
#                                    so they work even when the app is SSO-gated.
#                                    --out writes it to FILE instead of stdout
#
# Development access — calling an internal API for real, from the editor, so the
# response shape you build against is the actual one and not a guess from the spec:
#
#   request SLUG --reason "..."      ask the API's data owner for development access
#                                    (a PERSON's grant: read-only, expires, 7/30/90
#                                    days at the owner's choice). ≥10 characters.
#   access                           your own development access, every state
#   call SLUG [METHOD] PATH          one real request through the platform, which
#        [--accept TYPE] [--out FILE] attaches the credential you never see. METHOD is
#                                    GET (default), HEAD or OPTIONS — never a write.
#                                    PATH is the API's own path, query string
#                                    included. Body to stdout (or FILE); one status
#                                    line to stderr. Every call is recorded.
#
# Output is the API's JSON body untouched — the calling agent parses JSON natively,
# and the pure-shell _json_field helper can't walk arrays anyway.
#
# Reads need an ACCOUNT credential (personal access token, sbt_): the library is
# user-scoped, so an app-scoped deploy token (sbd_) is rejected by the server.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

# URL-encode just enough for query values (space and the JSON-ish specials that could
# appear in a search term). Pure shell, same portability constraints as _json_field.
_urlenc() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/&/%26/g' \
    -e 's/#/%23/g' -e 's/+/%2B/g' -e 's/?/%3F/g' -e 's|/|%2F|g'
}

# _check_auth — explain a 401/403 in library terms before dumping the body.
_check_auth() {
  case "${SUBSTRAIT_STATUS:-}" in
    401|403)
      echo "The library needs an ACCOUNT link (personal access token). An app deploy" >&2
      echo "token can't browse it — run /substrait:login to authorize your account." >&2
      ;;
  esac
}

cmd_list() {
  local q="" tag="" qs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --q)   q="${2:-}"; shift 2 ;;
      --tag) tag="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$q" ] && qs="?q=$(_urlenc "$q")"
  if [ -n "$tag" ]; then
    if [ -n "$qs" ]; then qs="$qs&tag=$(_urlenc "$tag")"; else qs="?tag=$(_urlenc "$tag")"; fi
  fi
  substrait_call GET "/api/library$qs" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Library list failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_show() {
  local kind="${1:-}" slug="${2:-}"
  case "$kind" in internal|app) ;; *) die "usage: show internal|app SLUG" ;; esac
  [ -n "$slug" ] || die "usage: show internal|app SLUG"
  # The API's collection segments are plural for apps, singular-adjective for internal.
  local seg="internal"; [ "$kind" = "app" ] && seg="apps"
  substrait_call GET "/api/library/$seg/$slug" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Library entry '$slug' failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_spec() {
  # Optional leading kind, mirroring `show`; a bare slug keeps the historical
  # internal-only behaviour.
  local kind="internal"
  case "${1:-}" in internal|app) kind="$1"; shift ;; esac
  local slug="${1:-}"; shift || true
  [ -n "$slug" ] || die "usage: spec [internal|app] SLUG [--out FILE]"
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  local seg="internal"; [ "$kind" = "app" ] && seg="apps"
  substrait_call GET "/api/library/$seg/$slug/spec" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Spec for '$slug' failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$SUBSTRAIT_BODY" > "$out" || die "could not write $out"
    echo "Wrote the OpenAPI spec for '$slug' to $out."
  else
    printf '%s\n' "$SUBSTRAIT_BODY"
  fi
}

# _json_str — a JSON string literal from a shell value. Escapes backslash, quote, tab,
# CR and newline; enough for a reason, a path or a media type. Line-by-line so it stays
# within what BSD sed (macOS) and GNU sed both do — no \r escapes, no label loops.
_json_str() {
  local out="" line first=1 tab cr
  tab="$(printf '\t')"; cr="$(printf '\r')"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
      -e "s/$tab/\\\\t/g" -e "s/$cr/\\\\r/g")"
    if [ $first -eq 1 ]; then out="$line"; first=0; else out="$out\\n$line"; fi
  done <<EOF
$1
EOF
  printf '"%s"' "$out"
}

# _detail — the portal's {detail} out of an error body, or the body itself.
_detail() { printf '%s' "$1" | _json_field detail 2>/dev/null || printf '%s' "$1"; }

cmd_request() {
  local slug="${1:-}"; shift || true
  [ -n "$slug" ] || die "usage: request SLUG --reason \"why you need it\""
  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ "${#reason}" -ge 10 ] || die "--reason must be at least 10 characters — it is the whole basis of the data owner's decision"
  local body
  body="{\"entry_slug\":$(_json_str "$slug"),\"reason\":$(_json_str "$reason")}"
  substrait_call POST /api/grants/development -H 'Content-Type: application/json' --data "$body" || exit $?
  case "${SUBSTRAIT_STATUS:-}" in
    201)
      echo "Requested development access to '$slug'. The data owner decides it; you'll get an email either way." >&2
      echo "Until then, design from the spec — 'call' will say when access is live." >&2
      printf '%s\n' "$SUBSTRAIT_BODY" ;;
    409)
      echo "Not sent — $(_detail "$SUBSTRAIT_BODY")" >&2; exit 1 ;;
    404)
      echo "No API '$slug' is available to your account (it may be hidden by a data group you don't hold — ask your org admin)." >&2; exit 1 ;;
    *)
      _check_auth
      echo "Request failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2; exit 1 ;;
  esac
}

cmd_access() {
  substrait_call GET /api/grants/mine || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _check_auth
    echo "Could not list your development access (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_call() {
  local slug="${1:-}"; shift || true
  [ -n "$slug" ] || die "usage: call SLUG [GET|HEAD|OPTIONS] PATH [--accept TYPE] [--out FILE]"
  local method="GET" path="" accept="" out=""
  case "${1:-}" in
    GET|HEAD|OPTIONS) method="$1"; shift ;;
    POST|PUT|PATCH|DELETE)
      die "development access is read-only: $1 is refused. Only GET, HEAD and OPTIONS may be made from the editor." ;;
  esac
  path="${1:-}"; shift || true
  [ -n "$path" ] || die "usage: call SLUG [GET|HEAD|OPTIONS] PATH — PATH is the API's own path from its spec, e.g. /2.0/shippers?limit=1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --accept) accept="${2:-}"; shift 2 ;;
      --out)    out="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  local body
  body="{\"method\":\"$method\",\"path\":$(_json_str "$path")"
  [ -n "$accept" ] && body="$body,\"accept\":$(_json_str "$accept")"
  body="$body}"
  local hdrs; hdrs="$(mktemp)" || die "mktemp failed"
  substrait_call POST "/api/library/internal/$slug/call" -H 'Content-Type: application/json' \
    --data "$body" -D "$hdrs" || { rc=$?; rm -f "$hdrs"; exit $rc; }
  case "${SUBSTRAIT_STATUS:-}" in
    200) ;;
    403)
      rm -f "$hdrs"
      echo "Refused: $(_detail "$SUBSTRAIT_BODY")" >&2
      echo "(Check where you stand with: substrait-library.sh access)" >&2; exit 1 ;;
    404) rm -f "$hdrs"; echo "Not callable: $(_detail "$SUBSTRAIT_BODY")" >&2; exit 1 ;;
    429) rm -f "$hdrs"; echo "Slow down: $(_detail "$SUBSTRAIT_BODY")" >&2; exit 1 ;;
    422) rm -f "$hdrs"; echo "Bad request: $SUBSTRAIT_BODY" >&2; exit 1 ;;
    502) rm -f "$hdrs"; echo "The platform could not complete the call: $(_detail "$SUBSTRAIT_BODY")" >&2; exit 1 ;;
    *)
      rm -f "$hdrs"; _check_auth
      echo "Call failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2; exit 1 ;;
  esac
  # 200 from the PLATFORM means it completed the call. What the API itself said rides
  # in X-Upstream-*; the body is the API's, verbatim, so the agent reads it exactly as
  # the app would. One status line to stderr keeps stdout clean for parsing.
  _hdr() { grep -i "^$1:" "$hdrs" | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//'; }
  local ustatus ums ubytes utrunc utype
  ustatus="$(_hdr X-Upstream-Status)"; ums="$(_hdr X-Upstream-Elapsed-Ms)"
  ubytes="$(_hdr X-Upstream-Bytes)"; utrunc="$(_hdr X-Upstream-Truncated)"
  utype="$(_hdr Content-Type)"
  rm -f "$hdrs"
  echo "$method $path → HTTP ${ustatus:-?} · ${ums:-?} ms · ${utype:-?} · ${ubytes:-?} bytes$([ "$utrunc" = "true" ] && printf ' · TRUNCATED at 1 MiB')" >&2
  if [ -n "$out" ]; then
    printf '%s\n' "$SUBSTRAIT_BODY" > "$out" || die "could not write $out"
    echo "Wrote the response body to $out." >&2
  else
    printf '%s\n' "$SUBSTRAIT_BODY"
  fi
}

case "${1:-list}" in
  list)    shift || true; cmd_list "$@" ;;
  show)    shift; cmd_show "$@" ;;
  spec)    shift; cmd_spec "$@" ;;
  request) shift; cmd_request "$@" ;;
  access)  shift || true; cmd_access "$@" ;;
  call)    shift; cmd_call "$@" ;;
  *) die "unknown command: ${1}. Use list|show|spec|request|access|call." ;;
esac
