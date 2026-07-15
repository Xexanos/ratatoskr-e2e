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
