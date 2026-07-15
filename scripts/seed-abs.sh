#!/usr/bin/env bash
# Seeds a fresh Audiobookshelf for the E2E run and emits the values the rest of the harness needs.
# Mirrors the server repo's packages/integration-tests/test/absSeed.ts, as plain curl + jq:
#   init root -> login -> create library -> forced scan -> poll until the item has a duration ->
#   create the app's end user -> create a stream-only user + its API key -> set an initial
#   listening position (so E2E-04 has something to resume from).
#
# Writes a dotenv file (default: <repo>/.e2e.env) with:
#   ABS_STREAMER_API_KEY  E2E_ABS_USER  E2E_ABS_PASS  E2E_ITEM_ID  E2E_RESUME_SECONDS  E2E_BOOK_DURATION
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/abs.sh
. "$here/lib/abs.sh"

ABS_BASE="${ABS_BASE:-http://localhost:13378}"
ENV_OUT="${1:-$(cd "$here/.." && pwd)/.e2e.env}"

ROOT_USER="root";     ROOT_PASS="rootpassword"
END_USER="${E2E_ABS_USER:-e2e}";           END_PASS="${E2E_ABS_PASS:-e2e-listener-pw1}"
STREAMER_USER="streamer";                  STREAMER_PASS="streamer-only-pw1"
RESUME_SECONDS="${E2E_RESUME_SECONDS:-120}"

log() { echo "seed-abs: $*" >&2; }
die() { echo "seed-abs: ERROR: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"

# HTTP helper. Echoes the response body; retries transient 5xx (ABS warm-up); surfaces 4xx.
# Args: METHOD PATH [JSON_BODY] [BEARER_TOKEN]. Records the HTTP code via last_code().
#
# The code is written to a file, not a shell global: most callers capture the body with
# `x="$(api …)"`, which runs api() in a subshell, so a global assignment would never reach the
# parent - a failed login would then die citing the code of the last *bare* api call (the /status
# probe, 200), an actively misleading diagnostic. A file survives the subshell.
CODE_FILE="$(mktemp)"
trap 'rm -f "$CODE_FILE"' EXIT
last_code() { cat "$CODE_FILE" 2>/dev/null || echo "?"; }
api() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}" attempt=0 code
  local bodyfile; bodyfile="$(mktemp)"
  while :; do
    attempt=$((attempt + 1))
    local args=(-sS -o "$bodyfile" -w '%{http_code}' -X "$method" "$ABS_BASE$path" -H "x-return-tokens: true")
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
    code="$(curl "${args[@]}" 2>/dev/null || echo 000)"
    if { [ "$code" = 000 ] || [ "$code" -ge 500 ]; } && [ "$attempt" -lt 45 ]; then
      sleep 2; continue
    fi
    printf '%s' "$code" > "$CODE_FILE"; cat "$bodyfile"; rm -f "$bodyfile"; return 0
  done
}

log "waiting for ABS at $ABS_BASE ..."
api GET /status >/dev/null
[ "$(last_code)" = 200 ] || die "ABS /status returned $(last_code)"

log "init root user (idempotent on a fresh instance)"
api POST /init "$(jq -nc --arg u "$ROOT_USER" --arg p "$ROOT_PASS" '{newRoot:{username:$u,password:$p}}')" >/dev/null || true

log "login as root"
admin="$(api POST /login "$(jq -nc --arg u "$ROOT_USER" --arg p "$ROOT_PASS" '{username:$u,password:$p}')" \
  | abs_token_from)"
[ -n "$admin" ] || die "could not obtain an admin token (login code $(last_code))"

log "create the Books library over /audiobooks"
lib="$(api POST /api/libraries '{"name":"Books","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book"}' "$admin" \
  | jq -r '.library.id // .id // empty')"
[ -n "$lib" ] || die "library creation failed (code $(last_code))"

log "force a scan (auto-scan on create is unreliable)"
api POST "/api/libraries/$lib/scan" "" "$admin" >/dev/null || true

log "wait for the fixture item to appear with a real duration"
item=""; duration=""
for _ in $(seq 1 45); do
  items="$(api GET "/api/libraries/$lib/items" "" "$admin")"
  item="$(printf '%s' "$items" | jq -r '.results[0].id // empty')"
  duration="$(printf '%s' "$items" | jq -r '(.results[0].media.duration // 0) | floor')"
  [ -n "$item" ] && [ "${duration:-0}" -gt 0 ] && break
  sleep 2
done
[ -n "$item" ] && [ "${duration:-0}" -gt 0 ] || die "fixture item never got a duration (last code $(last_code))"
log "item=$item duration=${duration}s"

create_user() { # username password -> prints user id
  local u="$1" p="$2"
  api POST /api/users "$(jq -nc --arg u "$u" --arg p "$p" '{username:$u,password:$p,type:"user",isActive:true}')" "$admin" >/dev/null || true
  api GET /api/users "" "$admin" | jq -r --arg u "$u" '.users[] | select(.username==$u) | .id'
}

log "create the app's end user ($END_USER)"
end_id="$(create_user "$END_USER" "$END_PASS")"
[ -n "$end_id" ] || die "end user not created"

log "create the stream-only user + API key"
streamer_id="$(create_user "$STREAMER_USER" "$STREAMER_PASS")"
[ -n "$streamer_id" ] || die "streamer user not created"
streamer_key="$(api POST /api/api-keys "$(jq -nc --arg n "ratatoskr-streamer" --arg id "$streamer_id" '{name:$n,userId:$id,isActive:true}')" "$admin" \
  | jq -r '.apiKey.apiKey // empty')"
[ -n "$streamer_key" ] || die "streamer API key not created (code $(last_code))"

log "set an initial listening position of ${RESUME_SECONDS}s for $END_USER"
end_token="$(api POST /login "$(jq -nc --arg u "$END_USER" --arg p "$END_PASS" '{username:$u,password:$p}')" \
  | abs_token_from)"
[ -n "$end_token" ] || die "could not log in as the end user"
api PATCH "/api/me/progress/$item" \
  "$(jq -nc --argjson t "$RESUME_SECONDS" --argjson d "$duration" '{currentTime:$t,duration:$d,isFinished:false}')" \
  "$end_token" >/dev/null
[ "$(last_code)" -lt 300 ] || die "setting initial progress failed (code $(last_code))"

umask 077
cat > "$ENV_OUT" <<EOF
ABS_STREAMER_API_KEY=$streamer_key
E2E_ABS_USER=$END_USER
E2E_ABS_PASS=$END_PASS
E2E_ITEM_ID=$item
E2E_RESUME_SECONDS=$RESUME_SECONDS
E2E_BOOK_DURATION=$duration
EOF
log "wrote $ENV_OUT"
