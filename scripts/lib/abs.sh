#!/usr/bin/env bash
# Shared Audiobookshelf helpers for the E2E scripts. ABS has renamed the login token field
# before (hence the three-way fallback), so the extraction lives in ONE place - a future churn is
# then a single-line fix here instead of three edits across seed-abs.sh and assert-abs-progress.sh.

# Extract the access token from an ABS /login response read on stdin (empty if none present).
abs_token_from() { jq -r '.user.token // .user.accessToken // .accessToken // empty'; }

# abs_login BASE USER PASS -> prints the access token on stdout (empty on failure). A plain
# one-shot login for callers that don't have seed-abs.sh's retrying api() wrapper.
abs_login() {
  local base="$1" user="$2" pass="$3"
  curl -sS -H 'x-return-tokens: true' -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" \
    "$base/login" 2>/dev/null | abs_token_from
}
