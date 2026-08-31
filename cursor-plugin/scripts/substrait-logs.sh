#!/usr/bin/env bash
# Tail the linked Substrait app's RUNNING pods (I-183).
#
#   [--component backend|frontend]  which container (default: backend)
#   [--tail N]                      lines per pod, 1-500 (default: 100)
#   [--previous]                    force the last TERMINATED instance's log
#
# This is the window /substrait:deploy --watch cannot reach. --watch follows a run and
# stops at PREVIEW_LIVE; the pipeline only captures pod output when a build/migration/
# smoke-test step FAILS. So an app that deployed green and then throws 500s in
# production leaves its traceback somewhere no plugin command could read — this is that
# command.
#
# Every pod for the component is printed, not just one. A wedged rollout has an old
# healthy ReplicaSet beside a new crash-looping one, and only the second explains the
# failure; showing "the" pod would return the healthy log and hide the problem.
#
# A crash-looping container is not running when we look, so the server reads its
# PREVIOUS instance automatically (nginx's exit-time [emerg] lives there, not in the
# empty current log). --previous forces that for a container that is merely restarting.
#
# ACCOUNT credential only (sbt_): the server gates this on a person, not on the app
# token in a project's config file — see SUBSTRAIT_REQUIRE_ACCOUNT in substrait-common.sh.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

# PAT-gated endpoint: resolve the account token and skip the project config, which in a
# linked project holds an sbd_ deploy token the server would refuse (B-004).
export SUBSTRAIT_REQUIRE_ACCOUNT=1

die() { echo "Error: $*" >&2; exit 1; }

component="backend"
tail_n="100"
previous="false"

# `shift 2` with only the flag left is a no-op that leaves $# unchanged, so the loop
# spins forever instead of erroring — and this command is driven by an agent, which can
# plausibly emit a bare `--tail`. A hung shell is a much worse failure than a message.
need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --component) need_value $# --component; component="$2"; shift 2 ;;
    --tail)      need_value $# --tail;      tail_n="$2";    shift 2 ;;
    --previous)  previous="true"; shift ;;
    -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$component" in
  backend|frontend) ;;
  *) die "--component must be backend or frontend (got: $component)" ;;
esac
case "$tail_n" in
  ''|*[!0-9]*) die "--tail must be a number 1-500 (got: $tail_n)" ;;
esac
[ "$tail_n" -ge 1 ] && [ "$tail_n" -le 500 ] || die "--tail must be 1-500 (got: $tail_n)"

substrait_call GET "/api/deploy/logs?component=$component&tail=$tail_n&previous=$previous" \
  || exit $?

case "${SUBSTRAIT_STATUS:-}" in
  200) ;;
  401)
    echo "Not signed in to an account — run /substrait:login." >&2
    echo "(Logs need a personal token: an app deploy token can't read them.)" >&2
    exit 1 ;;
  403)
    echo "Your account can't read this app's logs — you must be its owner or a" >&2
    echo "collaborator. Ask the owner to add you on the app's Sharing tab." >&2
    exit 1 ;;
  404)
    # Same status for "app not visible to you" and "no pods" — the body distinguishes.
    printf '%s\n' "$SUBSTRAIT_BODY" >&2
    # Point at the OTHER component, never the one just asked for. A backend-only app
    # renders its frontend Deployment at replicas 0, so "no frontend pods" is a normal
    # answer there and the useful next step is the backend.
    if [ "$component" = "backend" ]; then
      echo "(If the app is deployed, try --component frontend.)" >&2
    else
      echo "(This app may have no frontend — try the default --component backend.)" >&2
    fi
    exit 1 ;;
  409)
    echo "This app has never been deployed, so it has no logs yet." >&2
    exit 1 ;;
  *)
    echo "Unexpected response (HTTP ${SUBSTRAIT_STATUS:-?}):" >&2
    printf '%s\n' "$SUBSTRAIT_BODY" >&2
    exit 1 ;;
esac

# One pod object per line, then field-extract each. Same flat parsing constraint as the
# rest of the plugin (no jq/python3 guaranteed). FastAPI serialises compactly and in
# declaration order, so `{"pod":"` starts every object and the log is the last field.
#
# Splitting on that sequence is SAFE, not just lucky: every quote inside a log is escaped
# as \" in the JSON, so those exact bytes cannot occur within a log value no matter what
# the app printed — an app that logs `{"pod":"` verbatim arrives here as `{\"pod\":\"`.
printf '%s' "$SUBSTRAIT_BODY" | sed 's/{"pod":"/\
&/g' | awk '
  BEGIN { BS = sprintf("%c", 92) }   # a literal backslash, built without an escape
  /^\{"pod":"/ {
    pod=""; phase=""; ready=""; restarts=""; reason=""; prev=""; txt=""
    if (match($0, /"pod":"[^"]*"/))    { s=substr($0,RSTART,RLENGTH); sub(/^"pod":"/,"",s);    sub(/"$/,"",s); pod=s }
    if (match($0, /"phase":"[^"]*"/))  { s=substr($0,RSTART,RLENGTH); sub(/^"phase":"/,"",s);  sub(/"$/,"",s); phase=s }
    if (match($0, /"reason":"[^"]*"/)) { s=substr($0,RSTART,RLENGTH); sub(/^"reason":"/,"",s); sub(/"$/,"",s); reason=s }
    if (match($0, /"ready":(true|false)/))    { s=substr($0,RSTART,RLENGTH); sub(/^"ready":/,"",s);    ready=s }
    if (match($0, /"previous":(true|false)/)) { s=substr($0,RSTART,RLENGTH); sub(/^"previous":/,"",s); prev=s }
    if (match($0, /"restarts":[0-9]+/))       { s=substr($0,RSTART,RLENGTH); sub(/^"restarts":/,"",s); restarts=s }
    # log is the one field that carries escaped quotes and newlines, so it needs an
    # escape-aware match rather than [^"]*.
    if (match($0, /"log":"(\\.|[^"\\])*"/))   { s=substr($0,RSTART,RLENGTH); sub(/^"log":"/,"",s); sub(/"$/,"",s); txt=s }

    state = (ready == "true" ? "ready" : "NOT READY")
    if (reason != "") state = state " (" reason ")"
    if (restarts != "" && restarts != "0") state = state ", " restarts " restarts"
    printf "\n=== %s — %s, %s ===\n", pod, phase, state
    if (prev == "true") print "--- previous (terminated) instance ---"
    if (txt == "") { print "(no output)"; next }
    # Unescape in ONE left-to-right pass. Order matters and the obvious order is wrong:
    # handling \\ last means an app that logged `C:\temp` (on the wire: C:\\temp) has
    # its \\t eaten by the tab rule and prints as `C:<tab>emp`. Park escaped backslashes
    # on a sentinel byte first — SOH, which no app log realistically emits — so the
    # remaining rules can only ever see a genuine escape sequence.
    gsub(/\\\\/, "\001", txt)
    gsub(/\\r/, "", txt)
    gsub(/\\t/, "    ", txt)
    gsub(/\\n/, "\n", txt)
    gsub(/\\"/, "\"", txt)
    gsub(/\\\//, "/", txt)
    # Restore by CONCATENATION, not gsub: awks disagree on what a backslash in a gsub
    # replacement means — "\\" yields one backslash on macOS/BWK awk and two on gawk —
    # and these scripts run on whatever awk the user has. Concatenation does no escape
    # processing at all, so it is the same on every implementation.
    n = split(txt, part, /\001/)
    txt = part[1]
    for (i = 2; i <= n; i++) txt = txt BS part[i]
    print txt
  }'
