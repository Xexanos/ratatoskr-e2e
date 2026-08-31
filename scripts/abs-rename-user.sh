#!/usr/bin/env bash
# Renames an Audiobookshelf user through the admin API. The one fixture action E2E-12 needs.
#
# Why a rename: it is what makes Audiobookshelf refuse the refresh token of the chain the server
# stored for the app's device, and that refusal - a 401 on POST /auth/refresh, nothing else - is
# what marks the chain dead server-side (server ADR-0001 / SPEC §8). Deleting the account does the
# same, but takes the seeded listening position and the user id with it; a rename is reversible,
# which E2E-12 needs: the targeted re-login prompt sends only a password, so the account has to be
# back under its original name before the app signs in again.
#
# Confirmed against the ABS image compose.e2e.yaml pins: from the rename on, the stored refresh
# token is answered 401 {"error":"Invalid refresh token"} - and stays refused after the name is put
# back, so the chain remains dead no matter when the harness reverses this.
#
# Usage: abs-rename-user.sh FROM TO [ENV_FILE]
#   ENV_FILE defaults to <repo>/.e2e.env - seed-abs.sh writes the admin credentials there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/abs.sh
. "$here/lib/abs.sh"

from="${1:?usage: abs-rename-user.sh FROM TO [ENV_FILE]}"
to="${2:?usage: abs-rename-user.sh FROM TO [ENV_FILE]}"
ENV_FILE="${3:-$(cd "$here/.." && pwd)/.e2e.env}"
ABS_BASE="${ABS_BASE:-http://localhost:13378}"

log() { echo "abs-rename-user: $*" >&2; }
die() { echo "abs-rename-user: ERROR: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found (run scripts/seed-abs.sh via 'run-e2e.sh up' first)"
set -a; . "$ENV_FILE"; set +a
: "${E2E_ABS_ROOT_USER:?E2E_ABS_ROOT_USER not in $ENV_FILE (re-seed ABS)}"
: "${E2E_ABS_ROOT_PASS:?E2E_ABS_ROOT_PASS not in $ENV_FILE (re-seed ABS)}"

admin="$(abs_login "$ABS_BASE" "$E2E_ABS_ROOT_USER" "$E2E_ABS_ROOT_PASS")"
[ -n "$admin" ] || die "could not log in to $ABS_BASE as $E2E_ABS_ROOT_USER"

id="$(curl -sS -H "Authorization: Bearer $admin" "$ABS_BASE/api/users" 2>/dev/null \
  | jq -r --arg u "$from" '.users[]? | select(.username==$u) | .id')"
[ -n "$id" ] || die "no Audiobookshelf user named '$from'"

log "renaming '$from' -> '$to' (id $id)"
body="$(curl -sS -X PATCH "$ABS_BASE/api/users/$id" \
  -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg u "$to" '{username:$u}')" 2>/dev/null)"

# Read the name back out of the response rather than trusting the status code: a rejected update
# (a name already taken, say) would otherwise pass silently and leave E2E-12 waiting for a chain
# death that never comes. ABS answers such a rejection in plain text, not JSON, so jq's own failure
# is folded into the same "did not take" report instead of aborting with a parse error.
now="$(printf '%s' "$body" | jq -r '.user.username // empty' 2>/dev/null || true)"
[ "$now" = "$to" ] || die "rename did not take - ABS still reports '${now:-<no user in response>}' (body: $(printf '%s' "$body" | head -c 300))"
