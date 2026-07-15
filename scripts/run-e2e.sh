#!/usr/bin/env bash
# Orchestrates the E2E run. Split so CI can bring the stack up in one step and drive the app
# from inside the android-emulator-runner step (which owns the booted emulator + adb):
#
#   run-e2e.sh up      # make fixture, start ABS+fake, seed ABS, start the server, wait healthy
#   run-e2e.sh drive   # adb reverse + install APK + run Maestro flows + assert ABS progress
#   run-e2e.sh down     # tear the stack down
#   run-e2e.sh all      # up; drive; down   (local convenience; needs a running emulator + maestro)
#
# Image refs come from .e2e.artifacts.env (written by fetch-artifacts.sh) or the environment.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
COMPOSE=(docker compose -f compose.e2e.yaml)
ENV_FILE="$root/.e2e.env"
ARTIFACTS_ENV="$root/.e2e.artifacts.env"

# Source a dotenv file if it exists, exporting its vars. Returns 0 when the file is absent, so a
# bare call under `set -e` does not abort the script - the header promises image refs may come
# "from the environment" instead of a fetch-artifacts run, and the `:?` guards below are what
# should catch a truly missing value.
source_env() { [ -f "$1" ] || return 0; set -a; . "$1"; set +a; }
load_artifacts() { source_env "$ARTIFACTS_ENV"; }

wait_http() { # url [insecure] - poll until HTTP <400
  local url="$1" insecure="${2:-}" i
  for i in $(seq 1 60); do
    if curl -fsS ${insecure:+-k} -o /dev/null "$url" 2>/dev/null; then return 0; fi
    sleep 2
  done
  echo "run-e2e: timed out waiting for $url" >&2; return 1
}

cmd_up() {
  load_artifacts
  : "${SERVER_IMAGE:?set SERVER_IMAGE or run fetch-artifacts.sh}"
  : "${FAKE_SONOS_IMAGE:?set FAKE_SONOS_IMAGE or run fetch-artifacts.sh}"
  export SERVER_IMAGE FAKE_SONOS_IMAGE ${ABS_IMAGE:+ABS_IMAGE}

  bash "$root/scripts/make-fixture.sh"

  echo "run-e2e: starting ABS + fake-sonos"
  # ABS_STREAMER_API_KEY isn't known yet; give compose a placeholder so it doesn't error, then
  # start only the two services the server depends on.
  ABS_STREAMER_API_KEY="pending" "${COMPOSE[@]}" up -d abs fake-sonos

  wait_http "http://localhost:13378/status"
  echo "run-e2e: seeding ABS"
  bash "$root/scripts/seed-abs.sh" "$ENV_FILE"
  set -a; . "$ENV_FILE"; set +a   # ABS_STREAMER_API_KEY + fixture info

  echo "run-e2e: starting the server"
  "${COMPOSE[@]}" up -d ratatoskr
  wait_http "https://localhost:8080/v1/health" insecure

  # Record the server cert's SHA-256 fingerprint for the TOFU assertion (E2E-01). The entrypoint
  # generates a fresh self-signed cert per run, so it must be read at runtime. Format it exactly
  # as the app shows it - lowercase, colon-separated - so the Maestro assertVisible matches.
  echo "run-e2e: recording the server certificate fingerprint (E2E-01)"
  cert_fp="$(printf '' | openssl s_client -connect localhost:8080 -servername localhost 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr 'A-F' 'a-f')"
  [ -n "$cert_fp" ] || { echo "run-e2e: failed to read the server certificate fingerprint" >&2; exit 1; }
  echo "E2E_CERT_FP=$cert_fp" >> "$ENV_FILE"

  echo "run-e2e: stack is up (server healthy)"
}

cmd_drive() {
  load_artifacts
  source_env "$ENV_FILE"
  : "${APP_APK:?APP_APK not set (run fetch-artifacts.sh)}"
  command -v adb >/dev/null || { echo "run-e2e: adb not found (need a running emulator)" >&2; exit 1; }
  command -v maestro >/dev/null || { echo "run-e2e: maestro not found" >&2; exit 1; }

  echo "run-e2e: adb reverse + install"
  adb reverse tcp:8080 tcp:8080
  adb install -r -g "$APP_APK"

  echo "run-e2e: running Maestro flows"
  maestro test "$root/flows/p1-spine.yaml" \
    -e SERVER_URL="https://localhost:8080" \
    -e ABS_USER="$E2E_ABS_USER" -e ABS_PASS="$E2E_ABS_PASS" \
    -e BOOK_TITLE="Test Book" -e SPEAKER_NAME="E2E Test Room" \
    -e CERT_FP="$E2E_CERT_FP"

  echo "run-e2e: asserting ABS progress (E2E-06)"
  bash "$root/scripts/assert-abs-progress.sh" "$ENV_FILE"

  echo "run-e2e: pausing playback (E2E-05 pause)"
  maestro test "$root/flows/p1-pause.yaml"

  echo "run-e2e: asserting the fake speaker actually paused (E2E-05)"
  bash "$root/scripts/assert-fake-transport.sh" PAUSED_PLAYBACK

  echo "run-e2e: stopping playback (E2E-05 stop)"
  maestro test "$root/flows/p1-stop.yaml"

  echo "run-e2e: asserting the fake speaker actually stopped (E2E-05)"
  bash "$root/scripts/assert-fake-transport.sh" STOPPED

  cmd_p2
}

# ---- P2 failure cases (test-concept.md §5, E2E-07..10) ----
#
# Ordering is deliberate:
#   E2E-08 first - it must wait until the app's token is provably expired, and it leaves the app
#     with a FRESH token, which E2E-10 depends on (with ABS down, a 401's refresh would also fail
#     and surface "Sign-in expired." instead of the upstream error we want to see).
#   E2E-10 next (ABS down/up) - no active session, so the only moving part is the library query.
#   E2E-09 next (speaker down/up) - starts and loses a session; recovery ends session-less.
#   E2E-07 last - sign-out ends the signed-in state everything else depends on.
cmd_p2() {
  # E2E-08: the app must hold an access token OLDER than ACCESS_TOKEN_EXPIRY (90s in the
  # compose). The last possible rotation hand-over was the session stop just above (a pending
  # rotated pair is delivered on the stop response), so TTL + margin from here guarantees expiry.
  echo "run-e2e: E2E-08 - waiting 100s for the app's access token to expire"
  sleep 100
  echo "run-e2e: E2E-08 - cold start on an expired token must refresh silently"
  maestro test "$root/flows/p2-refresh.yaml" -e BOOK_TITLE="Test Book"

  echo "run-e2e: E2E-10 - stopping ABS (unreachable mid-run)"
  "${COMPOSE[@]}" stop abs
  maestro test "$root/flows/p2-abs-down.yaml"

  echo "run-e2e: E2E-10 - restarting ABS and waiting for it"
  "${COMPOSE[@]}" start abs
  wait_http "http://localhost:13378/status"
  maestro test "$root/flows/p2-abs-recovered.yaml" -e BOOK_TITLE="Test Book"

  echo "run-e2e: E2E-09 - starting a session to kill"
  maestro test "$root/flows/p2-session-start.yaml"
  echo "run-e2e: E2E-09 - stopping the fake speaker mid-session"
  "${COMPOSE[@]}" stop fake-sonos
  maestro test "$root/flows/p2-speaker-lost.yaml"
  echo "run-e2e: E2E-09 - restarting the fake speaker (comes back empty -> relinquish)"
  "${COMPOSE[@]}" start fake-sonos
  maestro test "$root/flows/p2-session-relinquished.yaml"

  echo "run-e2e: E2E-07 - signing out"
  maestro test "$root/flows/p2-signout.yaml"
}

cmd_down() { "${COMPOSE[@]}" down -v || true; }

case "${1:-all}" in
  up) cmd_up ;;
  drive) cmd_drive ;;
  down) cmd_down ;;
  # Tear down on exit (success or failure) so a failed local `all` run never leaves the stack up
  # with host ports 8080/13378 bound, colliding with the next attempt. (CI runs up/drive/down as
  # separate steps and relies on the workflow's if: always() teardown instead.)
  all) trap cmd_down EXIT; cmd_up; cmd_drive ;;
  *) echo "usage: run-e2e.sh {up|drive|down|all}" >&2; exit 2 ;;
esac
