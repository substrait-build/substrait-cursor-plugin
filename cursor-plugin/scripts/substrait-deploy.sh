#!/usr/bin/env bash
# Deploy the current project to its linked Substrait app. Two paths, picked by the
# app's mode (GET /api/deploy/app): a CONNECTED (GitHub) app is deployed by TRIGGER —
# the server pulls the pushed branch, so the tree must be committed + pushed (gated
# locally, verified server-side by SHA) — while every other app is packaged (source
# only) and uploaded as a zip.
#   --env <name>     deploy to that ENVIRONMENT of the app (e.g. staging) instead of
#                    production. The environment must already exist (the portal's
#                    environment switcher creates one). Also honoured: $SUBSTRAIT_ENV_TARGET
#                    and an "environment" key in .substrait/config.json.
#   --watch          poll the deploy until it finishes and print the preview URL
#   --stack <name>   override the recorded backend stack (default: auto-detected from
#                    backend/ — e.g. fastapi, python, node, go, rust, ruby, java, php,
#                    dotnet). Ignored for connected apps (the platform detects it).
#   promote --to <env> [--from <env>]
#                    promote one environment's LIVE build into another (default --from:
#                    the --env / pinned environment, else production): the target's
#                    database is migrated from that build's tree, its images copied and
#                    rolled out — no rebuild. A protected target (production) accepts
#                    this from the app owner or an admin only. With --watch follows it.
#   endpoints        submit .substrait/endpoints.json only, no deploy — legacy
#                    inventory-only fallback (prefer a repo-root openapi.json,
#                    which ships in the zip and is picked up server-side)
#   check            run the compliance audit only — no link, no token, no deploy,
#                    mutates nothing. Reports EVERY violation (the deploy preflight
#                    stops at the same checks). Exit 0 = compliant. Used by
#                    /substrait:init to audit a project before converting it.
# The platform is stack-agnostic (any Dockerfile that EXPOSEs 8000 + serves /health works);
# the stack is just a label shown in the portal. The app is determined by the project's
# .substrait/config.json — either its app-scoped deploy token, or (with an account link)
# its bound app slug (run /substrait:link first). Run from the project root (the dir
# containing backend/, frontend/, cicd/).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=substrait-common.sh
. "$DIR/substrait-common.sh"

die() { echo "Error: $*" >&2; exit 1; }

WATCH=0
STACK=""
ENDPOINTS_ONLY=0
CHECK_ONLY=0
PROMOTE=0; PROMOTE_TO=""; PROMOTE_FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    promote) PROMOTE=1; shift ;;
    --to) shift; PROMOTE_TO="${1:-}"; [ -n "$PROMOTE_TO" ] || die "--to needs an environment name (e.g. production)"; shift ;;
    --to=*) PROMOTE_TO="${1#*=}"; shift ;;
    --from) shift; PROMOTE_FROM="${1:-}"; [ -n "$PROMOTE_FROM" ] || die "--from needs an environment name (e.g. staging)"; shift ;;
    --from=*) PROMOTE_FROM="${1#*=}"; shift ;;
    endpoints) ENDPOINTS_ONLY=1; shift ;;
    check) CHECK_ONLY=1; shift ;;
    --watch) WATCH=1; shift ;;
    --env) shift; SUBSTRAIT_ENV_TARGET="${1:-}"; [ -n "$SUBSTRAIT_ENV_TARGET" ] || die "--env needs an environment name (e.g. staging)"; export SUBSTRAIT_ENV_TARGET; shift ;;
    --env=*) SUBSTRAIT_ENV_TARGET="${1#*=}"; export SUBSTRAIT_ENV_TARGET; shift ;;
    --stack) shift; STACK="${1:-}"; [ -n "$STACK" ] || die "--stack needs a value (e.g. node, go, fastapi)"; shift ;;
    --stack=*) STACK="${1#*=}"; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

# `check` mode: audit-only, before any link/token gates — an unlinked (or
# not-yet-Substrait) project must be checkable, that's the point. Read-only:
# no scaffold_version stamp, no packaging, no network.
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "Checking Substrait compliance…"
  if out="$(substrait_compliance_check)"; then
    echo "Compliant — the project meets the deploy contract's static checks."
    exit 0
  fi
  printf '%s\n' "$out"
  exit 1
fi

# detect_stack — best-effort guess of the backend stack from declaration files, so the
# label shown in the portal reflects what was actually shipped without the user passing
# --stack. Scans backend/ first (where the contract puts the backend), then the repo root.
# Pure file checks (+ one grep) so it stays dependency-free on Git Bash. Prints "other"
# when nothing matches; the platform accepts any short lowercase label regardless.
detect_stack() {
  local d
  for d in backend .; do
    [ -d "$d" ] || continue
    if [ -f "$d/go.mod" ]; then echo go; return; fi
    if [ -f "$d/Cargo.toml" ]; then echo rust; return; fi
    if [ -f "$d/requirements.txt" ] || [ -f "$d/pyproject.toml" ]; then
      if grep -qi 'fastapi' "$d/requirements.txt" "$d/pyproject.toml" 2>/dev/null; then echo fastapi; else echo python; fi
      return
    fi
    if [ -f "$d/Gemfile" ]; then echo ruby; return; fi
    if [ -f "$d/composer.json" ]; then echo php; return; fi
    if [ -f "$d/pom.xml" ] || [ -f "$d/build.gradle" ] || [ -f "$d/build.gradle.kts" ]; then echo java; return; fi
    if ls "$d"/*.csproj >/dev/null 2>&1; then echo dotnet; return; fi
    if [ -f "$d/package.json" ]; then echo node; return; fi
  done
  echo other
}

TOKEN="$(substrait_token 2>/dev/null)" || TOKEN=""
[ -n "$TOKEN" ] || die "not linked — run /substrait:link first."
# An account (sbt_) token authenticates the user; the project must also name its app.
if [ "${TOKEN#sbt_}" != "$TOKEN" ] && ! substrait_app_slug >/dev/null 2>&1; then
  die "this project isn't bound to an app yet — run /substrait:link to pick one."
fi
[ -d backend ] || die "no backend/ here — run this from the project root (the dir with backend/, cicd/)."

ENDPOINTS_FILE=".substrait/endpoints.json"
SPEC_FILE="openapi.json"   # repo-root, ships IN the zip — picked up server-side

# file_stale FILE — the artifact predates at least one backend/ source change.
# The /substrait:deploy instructions say "regenerate on every deploy", but an md step
# is a request, not a guarantee — this is the deterministic check that catches a
# forgotten regeneration before a stale spec/inventory ships. mtime-based on purpose:
# no dependency beyond find, and false positives are cheap (the fix is regenerate).
file_stale() {
  [ -f "$1" ] || return 1
  [ -n "$(find backend -type f -newer "$1" 2>/dev/null | head -1)" ]
}

# submit_endpoints [RUN_ID] — POST the legacy inventory-only file. Kept for projects
# that still generate .substrait/endpoints.json; a repo-root openapi.json supersedes it.
submit_endpoints() {
  local path="/api/deploy/endpoints"
  [ -n "${1:-}" ] && path="$path?run_id=$1"
  substrait_call POST "$path" \
    -H "Content-Type: application/json" --data-binary "@$ENDPOINTS_FILE"
  case "${SUBSTRAIT_STATUS:-}" in
    200|201)
      local n; n="$(grep -o '"path"' "$ENDPOINTS_FILE" | wc -l | tr -d ' ')"
      echo "Endpoint inventory submitted ($n endpoints)." ;;
    404) : ;;  # backend predates the endpoints API — silently skip
    *) echo "Warning: endpoint inventory not accepted (HTTP ${SUBSTRAIT_STATUS:-?}): ${SUBSTRAIT_BODY:-}" >&2
       return 1 ;;
  esac
}

# `endpoints` mode: submit the legacy inventory and exit — no packaging, no deploy.
if [ "$ENDPOINTS_ONLY" -eq 1 ]; then
  [ -f "$ENDPOINTS_FILE" ] || die "no $ENDPOINTS_FILE to submit — generate it first (see /substrait:deploy)."
  if file_stale "$ENDPOINTS_FILE"; then
    echo "Warning: $ENDPOINTS_FILE is older than the latest backend/ changes — regenerate it from the current source before submitting." >&2
  fi
  submit_endpoints || exit 1
  exit 0
fi

# Compliance preflight — fail fast & locally on the cheap, high-value parts of the
# deploy contract before we package and upload anything. The checks themselves live in
# substrait_compliance_check (substrait-common.sh) — shared with the standalone `check`
# mode above and /substrait:init — this wrapper just turns violations into a fatal error.
compliance_preflight() {
  local out
  if out="$(substrait_compliance_check)"; then return 0; fi
  printf '%s\n' "$out" >&2
  die "not Substrait-compliant — fix the issue(s) above and re-run /substrait:deploy."
}

# ── scaffold_version stamp ────────────────────────────────────────────────────────
# Record which skill/plugin version built this app: stamp `scaffold_version:` into
# substrait.yaml from the installed SKILL.md (self-located — same layout in the Cursor
# plugin), where the platform records it at deploy. The key is optional server-side,
# so anything unreadable here just skips (never blocks a deploy). For connected apps
# the stamp lands BEFORE the clean-tree gate on purpose: a changed manifest must be
# committed + pushed to ship, and that gate's message already says exactly that.
stamp_scaffold_version() {
  [ -f substrait.yaml ] || return 0   # the preflight owns the missing-manifest error
  local skill_md="$DIR/../skills/substrait-app/SKILL.md" ver cur
  [ -f "$skill_md" ] || return 0
  ver="$(sed -n 's/^version:[[:space:]]*//p' "$skill_md" | head -1 | tr -d '[:space:]')"
  [ -n "$ver" ] || return 0
  cur="$(sed -n 's/^[[:space:]]*scaffold_version[[:space:]]*:[[:space:]]*//p' substrait.yaml | head -1 | tr -d "[:space:]\"'")"
  [ "$cur" = "$ver" ] && return 0
  if [ -n "$cur" ]; then
    # -i.bak + rm: the one in-place form both BSD and GNU sed accept.
    sed -i.bak "s/^\([[:space:]]*scaffold_version[[:space:]]*:\).*/\1 $ver/" substrait.yaml \
      && rm -f substrait.yaml.bak
  else
    printf '\n# Skill/plugin version this app was last deployed with — stamped by\n# /substrait:deploy; do not edit by hand.\nscaffold_version: %s\n' "$ver" >> substrait.yaml
  fi
  STAMP_CHANGED=1
  echo "Stamped scaffold_version $ver into substrait.yaml."
}
# --to/--from only mean something with the promote verb; without it the script would
# otherwise fall through to packaging the working tree and uploading it — the opposite of
# a promotion.
if [ "$PROMOTE" -ne 1 ] && [ -n "$PROMOTE_TO$PROMOTE_FROM" ]; then
  die "--to/--from need the promote subcommand: substrait-deploy.sh promote --to <environment> [--from <environment>]"
fi
if [ "$PROMOTE" -eq 1 ]; then
  [ -n "$PROMOTE_TO" ] || die "usage: promote --to <environment> [--from <environment>] [--watch]"
  src="${PROMOTE_FROM:-$(substrait_env_target 2>/dev/null)}"; src="${src:-production}"
  src="$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')"
  to="$(printf '%s' "$PROMOTE_TO" | tr '[:upper:]' '[:lower:]')"
  echo "Promoting $src → $to (the live build of $src, no rebuild)…"
  substrait_call POST /api/deploy/promote -H "Content-Type: application/json" \
    --data "{\"from\":\"$src\",\"to\":\"$to\"}" || exit $?
  case "${SUBSTRAIT_STATUS:-}" in
    200|201|202) : ;;
    403) die "not allowed: $(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail || printf '%s' "$SUBSTRAIT_BODY")" ;;
    404|409) die "promotion not started: $(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail || printf '%s' "$SUBSTRAIT_BODY")" ;;
    *) die "promotion failed (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY" ;;
  esac
  RUN_ID="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field run_id)" || RUN_ID=""
  echo "Promotion queued (run $RUN_ID)."
  if [ "$WATCH" -ne 1 ] || [ -z "$RUN_ID" ]; then
    echo "Track it in the portal (the $to environment's deploy history)."
    exit 0
  fi
  # Follow it with the same watch loop a deploy uses. The status/log reads must target
  # the RUN's environment, so switch the header to the target; the packaging/upload
  # section in between is skipped.
  SUBSTRAIT_ENV_TARGET="$to"; export SUBSTRAIT_ENV_TARGET
  run_id="$RUN_ID"
  host=""
  if substrait_call GET /api/deploy/app && [ "${SUBSTRAIT_STATUS:-}" = "200" ]; then
    host="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field preview_hostname)" || host=""
  fi
  SKIP_TO_WATCH=1
fi

if [ "${SKIP_TO_WATCH:-0}" -ne 1 ]; then  # ── package + deploy (skipped for promote) ──
stamp_scaffold_version

echo "Checking Substrait compliance…"
compliance_preflight
echo "Compliance OK."

# The repo-root openapi.json (the app-authored API description) ships with the code
# and the platform records it at deploy — it BECOMES the app's published schema. A
# missing one mirrors the server's OPENAPI_SPEC_ENFORCEMENT policy (currently an
# advisory, planned to become a hard requirement); a stale one is worth flagging
# before it ships. Both warn-only here: the server owns the actual policy.
if [ ! -f "$SPEC_FILE" ]; then
  echo "Warning: no $SPEC_FILE at the project root — author the app's OpenAPI spec from the backend source (see /substrait:deploy). The platform currently records this as an advisory on the run; it is slated to become a hard requirement." >&2
fi
if file_stale "$SPEC_FILE"; then
  echo "Warning: $SPEC_FILE is older than the latest backend/ changes — it ships with this deploy as the app's published API description. Regenerate it from the current backend source first (see /substrait:deploy) unless you know it's still accurate." >&2
fi

# Which path does this app deploy by? A CONNECTED (GitHub) app deploys from its own
# repo — the server pulls the pushed branch, nothing is uploaded; everything else ships
# as a zip. An older backend reports no mode → zip path, where a connected app still
# gets the server's 409 guidance (same as before this branch existed).
MODE=""; CONN_REPO=""; CONN_BRANCH=""
# The deploy environment (see substrait_env_target): lower-cased like the server does, and
# re-exported so every later call in this script carries the same X-Substrait-Env.
ENV_TARGET="$(substrait_env_target 2>/dev/null)" || ENV_TARGET=""
if [ -n "$ENV_TARGET" ]; then SUBSTRAIT_ENV_TARGET="$ENV_TARGET"; export SUBSTRAIT_ENV_TARGET; fi
if substrait_call GET /api/deploy/app; then
  case "${SUBSTRAIT_STATUS:-}" in
    200)
      MODE="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field mode)" || MODE=""
      CONN_REPO="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field connected_repo)" || CONN_REPO=""
      CONN_BRANCH="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field connected_branch)" || CONN_BRANCH=""
      if [ -n "$ENV_TARGET" ] && [ "$ENV_TARGET" != "production" ]; then
        echo "Target environment: $ENV_TARGET"
      fi ;;
    404)
      # The server validates the environment on every /api/deploy route; its 404 detail
      # says which it was — an unknown environment, or an app that is gone/unbound.
      detail="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail)" || detail=""
      if [ -n "$ENV_TARGET" ] && printf '%s' "$detail" | grep -qi 'environment'; then
        die "$detail — create it on the app's page in the portal (the environment switcher), or drop --env to deploy production."
      fi ;;
  esac
fi

# Honor the project's recorded mode choice (deploy_mode in .substrait/config.json,
# written by `substrait-link.sh set-mode`). Unset = the server state decides, exactly
# as before the choice existed. A mismatch means the config was hand-edited or the
# app's connection changed elsewhere — refuse with the fix rather than guessing.
CHOSEN="$(_json_get "$SUBSTRAIT_CONFIG_FILE" deploy_mode 2>/dev/null)" || CHOSEN=""
if [ "$CHOSEN" = "connect" ] && [ "$MODE" != "connect" ]; then
  die "this project chose GitHub deploys but the app isn't connected to a repo — run /substrait:link and 'set-mode --mode connect --repo <owner/repo>' to connect it, or 'set-mode --mode upload' to go back to zip deploys."
fi
if [ "$CHOSEN" = "upload" ] && [ "$MODE" = "connect" ]; then
  die "this project chose zip deploys but the app deploys from $CONN_REPO — run /substrait:link and 'set-mode --mode upload' to disconnect it, or 'set-mode --mode connect' to record GitHub deploys."
fi

if [ "$MODE" = "connect" ]; then
  # ── Connected app: trigger a pull of the pushed branch. ──────────────────────
  # The gates below exist so the tree the server builds is EXACTLY the tree the
  # preflight above validated: everything committed AND pushed. The server
  # re-verifies the SHA authoritatively (409 on mismatch), so these are for fast,
  # actionable local errors — not the enforcement itself.
  [ -n "$STACK" ] && echo "Note: --stack is ignored for connected apps — the platform detects the stack from the repo." >&2
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "this app deploys from GitHub ($CONN_REPO@$CONN_BRANCH) but this directory isn't a git checkout — clone that repo and run /substrait:deploy from it."
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    stamp_note=""
    # Name the self-inflicted case: on a first deploy (or after a skill update) the
    # stamp above is what dirtied the tree — the fix is mechanical, say so.
    [ -n "${STAMP_CHANGED:-}" ] && stamp_note=" (this includes the scaffold_version stamp this script just wrote into substrait.yaml — that stamp itself must be committed)"
    die "uncommitted changes${stamp_note} — Substrait builds the PUSHED branch, so anything uncommitted (openapi.json and substrait.yaml included) won't ship. Commit and push, then re-run /substrait:deploy."
  fi
  cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$cur_branch" = "$CONN_BRANCH" ] \
    || die "this app deploys from branch '$CONN_BRANCH' but you're on '$cur_branch' — switch to (or merge into) '$CONN_BRANCH' first."
  if git remote get-url origin >/dev/null 2>&1 \
     && ! git remote get-url origin 2>/dev/null | grep -qi "$CONN_REPO"; then
    echo "Warning: this checkout's 'origin' doesn't look like $CONN_REPO — continuing; the server verifies the pushed commit." >&2
  fi
  # Freshness: HEAD must be what's actually pushed. Fetch is best-effort (offline or
  # credential-less fetch just skips the local check; the server still catches it).
  git fetch -q origin "$CONN_BRANCH" 2>/dev/null || true
  head_sha="$(git rev-parse HEAD)"
  upstream="$(git rev-parse "origin/$CONN_BRANCH" 2>/dev/null || git rev-parse '@{u}' 2>/dev/null)" || upstream=""
  if [ -n "$upstream" ] && [ "$head_sha" != "$upstream" ]; then
    die "local HEAD (${head_sha:0:12}) doesn't match the pushed tip of '$CONN_BRANCH' (${upstream:0:12}) — push your commits (or pull a teammate's), then re-run /substrait:deploy."
  fi

  echo "Deploying $CONN_REPO@$CONN_BRANCH (${head_sha:0:12}) — Substrait pulls the pushed branch…"
  substrait_call POST /api/deploy/trigger \
    -H "Content-Type: application/json" --data "{\"expected_sha\":\"$head_sha\"}" || exit $?
  case "${SUBSTRAIT_STATUS:-}" in
    200|201|202) : ;;
    409) die "deploy not triggered: $(printf '%s' "$SUBSTRAIT_BODY" | _json_field detail || printf '%s' "$SUBSTRAIT_BODY")" ;;
    *) die "deploy trigger failed (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY" ;;
  esac
else

# Resolve the backend stack label: explicit --stack wins, else auto-detect. Lowercased to
# match the server's accepted shape (a short lowercase slug).
[ -n "$STACK" ] || STACK="$(detect_stack)"
STACK="$(printf '%s' "$STACK" | tr '[:upper:]' '[:lower:]')"
echo "Backend stack: $STACK"

# package DEST — zip the project root, source only. Prefers `zip`; on a stock Windows /
# Git Bash machine (which has no `zip`) it stages a clean copy with `tar` — reusing the
# same exclude list — and compresses it with PowerShell's Compress-Archive. Returns 2 when
# no packager is available so the caller can give an actionable error.
package() {
  local dest="$1"
  if command -v zip >/dev/null 2>&1; then
    zip -rq "$dest" . \
      -x '.git/*' '*/.git/*' \
         'node_modules/*' '*/node_modules/*' \
         '.venv/*' '*/.venv/*' 'venv/*' '*/venv/*' \
         '__pycache__/*' '*/__pycache__/*' '*.pyc' \
         'dist/*' '*/dist/*' 'build/*' '*/build/*' \
         '.substrait/*' '.DS_Store' '*/.DS_Store'
    return $?
  fi
  local ps; ps="$(command -v powershell.exe || command -v pwsh.exe || command -v pwsh || true)"
  if [ -n "$ps" ] && command -v tar >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    local stage; stage="$(mktemp -d)" || return 1
    tar -cf - \
      --exclude='./.git' --exclude='*/.git' --exclude='./node_modules' --exclude='*/node_modules' \
      --exclude='./.venv' --exclude='*/.venv' --exclude='./venv' --exclude='*/venv' \
      --exclude='__pycache__' --exclude='*.pyc' --exclude='./dist' --exclude='*/dist' \
      --exclude='./build' --exclude='*/build' --exclude='./.substrait' --exclude='.DS_Store' . \
      | tar -xf - -C "$stage" || { rm -rf "$stage"; return 1; }
    "$ps" -NoProfile -NonInteractive -Command \
      "Compress-Archive -Path '$(cygpath -w "$stage")\\*' -DestinationPath '$(cygpath -w "$dest")' -Force" \
      || { rm -rf "$stage"; return 1; }
    rm -rf "$stage"
    return 0
  fi
  return 2
}

# 1. Zip the project root, source only. The platform discards build artifacts anyway,
#    and the 16 MB cap is easy to blow with node_modules/.venv present.
zip_path="$(mktemp -t substrait-XXXXXX).zip"
trap 'rm -f "$zip_path"' EXIT
echo "Packaging (source only)…"
package "$zip_path"; pkg_rc=$?
[ "$pkg_rc" -eq 2 ] && die "no 'zip' command found and no PowerShell fallback available — install zip (or run from an environment that has it) and retry."
[ "$pkg_rc" -ne 0 ] && die "packaging failed"

size=$(wc -c < "$zip_path" | tr -d ' ')
max=$((16 * 1024 * 1024))
if [ "$size" -gt "$max" ]; then
  die "zip is $((size/1024/1024)) MB (max 16 MB). Exclude build output / large assets and retry."
fi
echo "Packaged $((size/1024)) KB."

# 2. Deploy the token's app (the app is inferred server-side from the token).
echo "Deploying…"
substrait_call POST /api/deploy \
  -F "file=@$zip_path;type=application/zip;filename=upload.zip" \
  -F "backend_stack=$STACK" || exit $?
case "${SUBSTRAIT_STATUS:-}" in
  200|201|202) : ;;
  *) die "deploy failed (HTTP $SUBSTRAIT_STATUS): $SUBSTRAIT_BODY" ;;
esac

fi  # connect vs zip — both leave the same {project, run_id} body in SUBSTRAIT_BODY

run_id="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field run_id)"
# host lives under the nested "project" object; a flat first-match grep finds it (it's the
# only preview_hostname/slug in the body), falling back to the slug-derived hostname.
host="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field preview_hostname)"
[ -n "$host" ] || { slug="$(printf '%s' "$SUBSTRAIT_BODY" | _json_field slug)"; host="${slug}.apps.substrait.build"; }
echo "Deploy queued — run #$run_id."

# 3. Submit the legacy endpoint inventory, if one exists and no repo-root openapi.json
#    supersedes it (the spec ships with the code — in the zip, or committed in the
#    connected repo — and the platform records it server-side at deploy, so there is
#    nothing to submit here). Runs AFTER the deploy
#    fields above are parsed out of SUBSTRAIT_BODY (substrait_call overwrites the
#    globals). Best-effort and non-fatal; a STALE file is deliberately NOT submitted —
#    a wrong inventory is worse than last deploy's.
if [ ! -f "$SPEC_FILE" ] && [ -f "$ENDPOINTS_FILE" ]; then
  if file_stale "$ENDPOINTS_FILE"; then
    {
      echo "Warning: $ENDPOINTS_FILE is older than the latest backend/ changes — NOT submitting it."
      echo "  Regenerate it from the current backend source, then resubmit (no redeploy needed):"
      echo "    bash \"$DIR/substrait-deploy.sh\" endpoints"
      echo "  (Better: author a full openapi.json at the repo root — see /substrait:deploy.)"
    } >&2
  else
    submit_endpoints "$run_id" || true
  fi
fi

# Keep the project's CLAUDE.md "Substrait deployment" block current (only if one
# exists — its removal is a durable opt-out; /substrait:link is what adds it).
substrait_write_memo refresh

fi  # ── end package + deploy ──

if [ "$WATCH" -ne 1 ]; then
  echo "Track it in the portal; once live it'll be at https://$host"
  exit 0
fi

# 4. Poll the deploy status until this run reaches a terminal state, streaming the run's
#    event log alongside. The events carry the actual build/migration/smoke-test detail
#    (incl. an 80-line pod-log tail on failures), so when a deploy breaks the error lands
#    right here in the transcript where the coding agent can read it and fix the app —
#    no portal round-trip. A backend that predates the events endpoint 404s; we silently
#    degrade to state-only watching.
echo "Watching deploy… (Ctrl-C to stop watching; the deploy keeps running)"
deadline=$(( $(date +%s) + 900 ))   # 15 min ceiling
last=""
last_seq=0

# print_events — fetch this run's events newer than $last_seq, print them, advance
# $last_seq. Heartbeat rows ("BUILD_BACKEND: active (45s/600s)") are elided — they would
# swamp the transcript and the status poll already shows phase changes. Same flat-grep
# JSON parsing as the status poll: field order is server-controlled (level precedes
# message), and message is the one field that may carry escaped quotes/newlines (log
# tails), so it gets an escape-aware match + unescape.
print_events() {
  [ -n "$run_id" ] || return 0
  substrait_call GET "/api/deploy/runs/$run_id/events?after_seq=$last_seq" || return 0
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || return 0
  local rows max
  rows="$(printf '%s' "$SUBSTRAIT_BODY" | sed 's/},[[:space:]]*{/}\
{/g')"
  # rows are seq-ascending, so the last seq in the body is the high-water mark.
  max="$(printf '%s' "$rows" | grep -o '"seq"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | grep -o '[0-9][0-9]*$' | tail -1)"
  printf '%s\n' "$rows" | awk '
    {
      lvl=""; msg=""
      if (match($0, /"level"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"level"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); lvl=s }
      if (match($0, /"message"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^"message"[[:space:]]*:[[:space:]]*"/,"",s); sub(/"$/,"",s); msg=s }
      if (msg == "") next
      if (msg ~ /\([0-9]+s\/[0-9]+s\)$/) next     # elide heartbeats
      gsub(/\\r/, "", msg)
      gsub(/\\n/, "\n        ", msg)              # keep log tails aligned under their event
      gsub(/\\t/, "    ", msg)
      gsub(/\\"/, "\"", msg)
      if (lvl == "error")                        printf "    ✗ %s\n", msg
      else if (lvl == "warn" || lvl == "warning") printf "    ! %s\n", msg
      else                                        printf "      %s\n", msg
    }'
  [ -n "$max" ] && last_seq="$max"
}

while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 8
  print_events
  substrait_call GET /api/deploy/status || continue
  [ "${SUBSTRAIT_STATUS:-}" = "200" ] || continue
  # Split the array into one object per line, then find the row whose id == run_id and
  # print its state; fall back to the first (most recent) row's state if no id matches.
  state="$(printf '%s' "$SUBSTRAIT_BODY" | sed 's/},[[:space:]]*{/}\
{/g' | awk -v rid="$run_id" '
    { id=""; st="";
      if (match($0,/"id"[[:space:]]*:[[:space:]]*"?[^",}]+/)) { s=substr($0,RSTART,RLENGTH); sub(/.*:[[:space:]]*"?/,"",s); id=s }
      if (match($0,/"state"[[:space:]]*:[[:space:]]*"[^"]*"/)) { s=substr($0,RSTART,RLENGTH); sub(/.*:[[:space:]]*"/,"",s); sub(/"$/,"",s); st=s }
      if (NR==1) first=st
      if (id==rid) { print st; found=1; exit } }
    END { if (!found) print first }')"
  if [ "$state" != "$last" ] && [ -n "$state" ]; then echo "  • $state"; last="$state"; fi
  # Terminal states: drain any events written after our last fetch (the failure detail
  # usually lands in the same instant as the state flip) before reporting.
  case "$state" in
    PREVIEW_LIVE) print_events; echo "✅ Live: https://$host"; exit 0 ;;
    FAILED|ERROR)
      print_events
      die "deploy failed (state $state) — the ✗ events above say why. Fix the app and re-run /substrait:deploy (full log in the portal, run #$run_id)." ;;
  esac
done
echo "Still running after 15 min — check the portal for run #$run_id (https://$host when live)."
