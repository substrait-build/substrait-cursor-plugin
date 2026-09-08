#!/usr/bin/env bash
# Manage the linked Substrait app's environment variables and secrets.
#
#   list                         all vars as JSON (secret values are null — write-only)
#   set NAME [VALUE] [--secret]  create/update one var; --secret stores it write-only
#                                (masked in the portal). With VALUE omitted the value is
#                                read from STDIN (use for secrets — keeps the value out
#                                of the command line — and for multi-line values).
#   unset NAME                   remove one var
#   --env NAME (any command)     act on that ENVIRONMENT of the app (e.g. staging) instead
#                                of production; also $SUBSTRAIT_ENV_TARGET / an "environment"
#                                key in .substrait/config.json. Each environment has its
#                                own vars.
#
# Every mutation live-applies: on a deployed app the platform reconciles the app's
# Secret and rolls the backend within seconds ("applied": true in the response);
# otherwise the value is stored and folded into the next deploy.
#
# Works with either credential /substrait:link sets up (app deploy token, or personal
# token + this project's bound app slug). Platform-injected names (DATABASE_URL,
# JWT_SECRET, REDIS_URL, KAFKA_BROKERS, QDRANT_URL) are rejected server-side.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

# JSON-escape stdin. Pure shell/awk on purpose (same portability constraint as
# _json_field in substrait-common.sh: no jq/python3 guaranteed). Handles backslash,
# double-quote, tab, CR, and joins multi-line input with \n — enough for real env
# values including PEM blocks; other control characters are not expected in env vars.
_json_escape() {
  awk 'BEGIN{ORS=""}
       {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"\\r");
        if (NR>1) printf "\\n"; printf "%s", $0}'
}

# Same name rule the server enforces (POSIX-ish env name) — checked client-side so the
# name is always safe to place in the request path unencoded.
_check_name() {
  case "$1" in
    [A-Za-z_]*) printf '%s' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' && return 0 ;;
  esac
  die "invalid name '$1' — use letters, digits and underscores, not starting with a digit"
}

_explain_status() {
  case "${SUBSTRAIT_STATUS:-}" in
    401|403) echo "Not authorised — run /substrait:link to (re)connect this project." >&2 ;;
    422)     echo "The platform rejected the variable (reserved or invalid name, or empty value)." >&2 ;;
  esac
}

# _report_applied set|unset — one friendly line after a mutation, from the response's
# "applied" flag (true = the app is deployed and the live Secret is being reconciled).
_report_applied() {
  case "$SUBSTRAIT_BODY" in
    *'"applied":true'*|*'"applied": true'*)
      echo "Applied to the running app (the backend restarts with the change in a few seconds)." ;;
    *)
      if [ "$1" = "set" ]; then
        echo "Stored. The app isn't deployed yet — the value is injected on the next deploy."
      else
        echo "Removed from the stored config (the app isn't deployed yet)."
      fi ;;
  esac
}

cmd_list() {
  substrait_call GET "/api/deploy/env-vars" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _explain_status
    echo "Listing env vars failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  printf '%s\n' "$SUBSTRAIT_BODY"
}

cmd_set() {
  local name="" value="" have_value=0 secret=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --secret) secret=true; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        if [ -z "$name" ]; then name="$1"
        elif [ "$have_value" = 0 ]; then value="$1"; have_value=1
        else die "unexpected argument: $1"
        fi
        shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: set NAME [VALUE] [--secret]   (VALUE omitted → read stdin)"
  if [ "$have_value" = 0 ]; then
    value="$(cat)"
    # Strip one trailing newline (printf '%s\n' pipes and heredocs add it; a value that
    # genuinely ends in a newline is not a thing for env vars).
    value="${value%$'\n'}"
  fi
  [ -n "$value" ] || die "empty value — use 'unset $name' to remove the variable"
  _check_name "$name"
  local esc_value
  esc_value="$(printf '%s' "$value" | _json_escape)"
  substrait_call PUT "/api/deploy/env-vars/$name" \
    -H "Content-Type: application/json" \
    -d "{\"value\":\"$esc_value\",\"is_secret\":$secret}" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _explain_status
    echo "Setting $name failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  if [ "$secret" = true ]; then
    echo "Secret $name saved (write-only — it will never be echoed back)."
  else
    echo "Env var $name saved."
  fi
  _report_applied set
}

cmd_unset() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: unset NAME"
  _check_name "$name"
  substrait_call DELETE "/api/deploy/env-vars/$name" || exit $?
  if [ "${SUBSTRAIT_STATUS:-}" != "200" ]; then
    _explain_status
    echo "Removing $name failed (HTTP ${SUBSTRAIT_STATUS:-?}): $SUBSTRAIT_BODY" >&2
    exit 1
  fi
  echo "Removed $name."
  _report_applied unset
}

# Global --env, anywhere on the line: consumed here so every subcommand targets the
# same environment (substrait_common's substrait_call sends it as X-Substrait-Env).
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --env) shift; [ -n "${1:-}" ] || die "--env needs an environment name (e.g. staging)"; SUBSTRAIT_ENV_TARGET="$1"; export SUBSTRAIT_ENV_TARGET; shift ;;
    --env=*) SUBSTRAIT_ENV_TARGET="${1#*=}"; export SUBSTRAIT_ENV_TARGET; shift ;;
    *) _args+=("$1"); shift ;;
  esac
done
set -- "${_args[@]+"${_args[@]}"}"
if t="$(substrait_env_target 2>/dev/null)" && [ -n "$t" ] && [ "$t" != "production" ]; then
  echo "Environment: $t" >&2
fi

case "${1:-list}" in
  list)  shift || true; cmd_list "$@" ;;
  set)   shift; cmd_set "$@" ;;
  unset) shift; cmd_unset "$@" ;;
  *) die "unknown command: ${1}. Use list|set|unset." ;;
esac
