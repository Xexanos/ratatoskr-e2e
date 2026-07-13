#!/usr/bin/env bash
# E2E-06: assert the server synced the listening position back to ABS (the source of truth).
# Reads the end user's media progress directly from ABS - not the app UI - so it is real proof
# the position persisted. Expects the position to have ADVANCED past the seeded start (the app
# resumed there and played), and to stay within the book. Reads config from <repo>/.e2e.env.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ABS_BASE="${ABS_BASE:-http://localhost:13378}"
# shellcheck disable=SC1090
. "${1:-$root/.e2e.env}"

command -v jq >/dev/null || { echo "assert-abs-progress: jq required" >&2; exit 1; }

token="$(curl -sS -H 'x-return-tokens: true' -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg u "$E2E_ABS_USER" --arg p "$E2E_ABS_PASS" '{username:$u,password:$p}')" \
  "$ABS_BASE/login" | jq -r '.user.token // .user.accessToken // .accessToken // empty')"
[ -n "$token" ] || { echo "assert-abs-progress: could not log in as $E2E_ABS_USER" >&2; exit 1; }

current="$(curl -sS -H "Authorization: Bearer $token" "$ABS_BASE/api/me/progress/$E2E_ITEM_ID" \
  | jq -r '(.currentTime // 0)')"
current="${current%.*}"  # floor to whole seconds

echo "assert-abs-progress: ABS currentTime=${current}s (start was ${E2E_RESUME_SECONDS}s, duration ${E2E_BOOK_DURATION}s)"

if [ -z "$current" ] || [ "$current" -le "$E2E_RESUME_SECONDS" ]; then
  echo "assert-abs-progress: FAIL - position did not advance past the resume point; sync did not reach ABS" >&2
  exit 1
fi
if [ "$current" -ge "$E2E_BOOK_DURATION" ]; then
  echo "assert-abs-progress: FAIL - position ${current}s is beyond the book (${E2E_BOOK_DURATION}s)" >&2
  exit 1
fi
echo "assert-abs-progress: PASS - progress advanced to ${current}s and was persisted to ABS"
