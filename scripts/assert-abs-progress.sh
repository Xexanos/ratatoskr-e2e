#!/usr/bin/env bash
# E2E-06: assert the server keeps syncing the listening position back to ABS (the source of
# truth). Reads the end user's media progress directly from ABS - not the app UI - so it is real
# proof the position persisted. The app resumed at the seeded start and is still playing, so the
# position must (a) climb past the seeded start and stay within the book, and (b) keep MOVING:
# two samples a few seconds apart must strictly increase. A broken sync loop that only wrote the
# position once (say, in the pause handler) would satisfy (a) but not (b). Config: <repo>/.e2e.env.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ABS_BASE="${ABS_BASE:-http://localhost:13378}"
# shellcheck source=scripts/lib/abs.sh
. "$here/lib/abs.sh"
# shellcheck disable=SC1090
. "${1:-$root/.e2e.env}"

command -v jq >/dev/null || { echo "assert-abs-progress: jq required" >&2; exit 1; }

token="$(abs_login "$ABS_BASE" "$E2E_ABS_USER" "$E2E_ABS_PASS")"
[ -n "$token" ] || { echo "assert-abs-progress: could not log in as $E2E_ABS_USER" >&2; exit 1; }

# Read ABS currentTime, floored to whole seconds. Guarded end to end: curl has no -f, so a 5xx
# error body would reach jq, and a dropped connection or non-JSON body would make the assignment
# fail - under set -e that kills the whole poll mid-loop and the diagnostics never print. Any such
# hiccup yields 0 here and simply becomes the next retry.
read_current() {
  local v
  v="$(curl -sS -H "Authorization: Bearer $token" "$ABS_BASE/api/me/progress/$E2E_ITEM_ID" 2>/dev/null \
    | jq -r '(.currentTime // 0)' 2>/dev/null || echo 0)"
  v="${v%.*}"
  [ -n "$v" ] && [ "$v" -eq "$v" ] 2>/dev/null || v=0   # non-numeric (empty body, error) -> 0
  echo "$v"
}

# (a) Wait for the position to cross the resume point - the server needs a moment to write the
# resumed, advancing position once the app starts playing.
prev=""
for _ in $(seq 1 15); do
  current="$(read_current)"
  echo "assert-abs-progress: ABS currentTime=${current}s (start ${E2E_RESUME_SECONDS}s, duration ${E2E_BOOK_DURATION}s)"
  if [ "$current" -gt "$E2E_RESUME_SECONDS" ] && [ "$current" -lt "$E2E_BOOK_DURATION" ]; then
    prev="$current"; break
  fi
  sleep 2
done
[ -n "$prev" ] || {
  echo "assert-abs-progress: FAIL - position never advanced past the resume point (${E2E_RESUME_SECONDS}s); the server did not sync a resumed position to ABS." >&2
  exit 1
}

# (b) A later sample must be strictly greater - proof the sync loop keeps writing, not a one-shot.
for _ in $(seq 1 10); do
  sleep 3
  current="$(read_current)"
  echo "assert-abs-progress: resample ABS currentTime=${current}s (was ${prev}s)"
  if [ "$current" -gt "$prev" ] && [ "$current" -lt "$E2E_BOOK_DURATION" ]; then
    echo "assert-abs-progress: PASS - progress advanced ${prev}s -> ${current}s and is still being synced to ABS"
    exit 0
  fi
done

echo "assert-abs-progress: FAIL - position reached ${prev}s but stopped advancing; a moving position is not being synced to ABS." >&2
exit 1
