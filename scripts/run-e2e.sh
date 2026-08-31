#!/usr/bin/env bash
# Orchestrates the E2E run. Split so CI can bring the stack up in one step and drive the app
# from inside the android-emulator-runner step (which owns the booted emulator + adb):
#
#   run-e2e.sh up        # make fixture, start ABS+fake, seed ABS, start the server, wait healthy
#   run-e2e.sh drive     # adb reverse + install APK + P1 spine + P2 failure cases + asserts
#   run-e2e.sh drive-p1  # prep + only the P1 spine half (fast iteration on a P1 regression)
#   run-e2e.sh drive-p2  # prep + only the P2 failure cases (resume after a P1 run - see cmd_p2)
#   run-e2e.sh down      # tear the stack down
#   run-e2e.sh all       # up; drive; down   (local convenience; needs a running emulator + maestro)
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

# Poll the fake Sonos AVTransport (published on :1400) until it answers SOAP. `compose start
# fake-sonos` returns before the fake's SOAP server listens, so without this a slow container start
# eats into the flow's own timing budget - symmetric with wait_http before the ABS recovery flow.
# GetTransportInfo is the same request assert-fake-transport.sh issues.
wait_fake_soap() {
  local i ctrl='http://localhost:1400/MediaRenderer/AVTransport/Control'
  local soap='<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo></s:Body></s:Envelope>'
  for i in $(seq 1 30); do
    if curl -fsS -o /dev/null -X POST "$ctrl" \
         -H 'Content-Type: text/xml; charset=utf-8' \
         -H 'SOAPACTION: "urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo"' \
         --data "$soap" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "run-e2e: timed out waiting for the fake Sonos SOAP endpoint on :1400" >&2; return 1
}

cmd_up() {
  load_artifacts
  : "${SERVER_IMAGE:?set SERVER_IMAGE or run fetch-artifacts.sh}"
  : "${FAKE_SONOS_IMAGE:?set FAKE_SONOS_IMAGE or run fetch-artifacts.sh}"
  export SERVER_IMAGE FAKE_SONOS_IMAGE ${ABS_IMAGE:+ABS_IMAGE}

  bash "$root/scripts/make-fixture.sh"

  echo "run-e2e: starting ABS + fake-sonos"
  # ABS_STREAMER_API_KEY and SESSION_STORE_KEY aren't known yet; give compose placeholders so it
  # doesn't error, then start only the two services the server depends on.
  ABS_STREAMER_API_KEY="pending" SESSION_STORE_KEY="pending" \
    "${COMPOSE[@]}" up -d abs fake-sonos

  wait_http "http://localhost:13378/status"
  echo "run-e2e: seeding ABS"
  bash "$root/scripts/seed-abs.sh" "$ENV_FILE"
  set -a; . "$ENV_FILE"; set +a   # ABS_STREAMER_API_KEY + fixture info

  # Session-store key for the server (post-ADR-0001 images refuse to boot without one). Persisted
  # to .e2e.env like ABS_STREAMER_API_KEY so every later compose invocation in this run - cmd_p2's
  # stop/start cycles, a standalone drive - re-loads the SAME key: a key that changed mid-run would
  # make the persisted store unreadable and fail tests for the wrong reason. seed-abs.sh rewrites
  # .e2e.env just above, so appending here also guarantees a FRESH key per `up`, matching the fresh
  # store volume from cmd_down's `down -v`.
  SESSION_STORE_KEY="$(openssl rand -base64 32)"
  export SESSION_STORE_KEY
  echo "SESSION_STORE_KEY=$SESSION_STORE_KEY" >> "$ENV_FILE"

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

# Pin the device UI locale to en-US (test-concept.md §9). The flows select by the app's English
# text, and the app ships more UI languages (en-US + de-DE), so a device defaulting to another
# locale fails the suite's very first assertVisible. Pinned at DEVICE level on purpose: the
# per-app alternative (cmd locale set-app-locales) is wiped by the `pm clear` behind Maestro's
# clearState launches, while the device locale - the fallback the app then resolves - survives it.
# Setting persist.sys.locale needs adb root + a zygote restart; both are available on the
# `default` (non-Google) emulator images CI uses. The effective-locale check up front means a
# device already on en-US (every stock CI emulator) skips the restart entirely.
pin_locale() {
  local want="en-US" cur
  cur="$(adb shell getprop persist.sys.locale </dev/null | tr -d '\r')"
  [ -n "$cur" ] || cur="$(adb shell getprop ro.product.locale </dev/null | tr -d '\r')"
  [ "$cur" = "$want" ] && return 0
  echo "run-e2e: pinning the device locale to $want (was: ${cur:-unset})"
  adb root >/dev/null   # restarts adbd - run before adb reverse, which an adbd restart would drop
  adb wait-for-device
  adb shell "setprop persist.sys.locale $want; setprop ctl.restart zygote" </dev/null
  local i
  for i in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed </dev/null 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  cur="$(adb shell getprop persist.sys.locale </dev/null | tr -d '\r')"
  [ "$cur" = "$want" ] || { echo "run-e2e: failed to pin the device locale to $want (got: ${cur:-unset})" >&2; return 1; }
}

# Shared prep for any drive verb: load env + fixture facts, require the APK and tools, wire adb.
drive_prep() {
  load_artifacts
  source_env "$ENV_FILE"
  : "${APP_APK:?APP_APK not set (run fetch-artifacts.sh)}"
  : "${E2E_BOOK_TITLE:?E2E_BOOK_TITLE not set (run scripts/seed-abs.sh via 'up' first)}"
  command -v adb >/dev/null || { echo "run-e2e: adb not found (need a running emulator)" >&2; exit 1; }
  command -v maestro >/dev/null || { echo "run-e2e: maestro not found" >&2; exit 1; }

  pin_locale   # before adb reverse: pinning may restart adbd, which drops reverses

  echo "run-e2e: adb reverse + install"
  adb reverse tcp:8080 tcp:8080
  # The cached AVD's data image can carry the app from the run that saved the cache, signed with
  # that run's debug keystore. Normally invisible (the quick-boot snapshot restores a clean state),
  # but when an emulator update invalidates the snapshot, the AVD cold-boots off the dirty image and
  # `install -r` dies with INSTALL_FAILED_UPDATE_INCOMPATIBLE on the signature mismatch. A fresh
  # install is wanted here anyway, so remove any leftover first; absent package exits non-zero,
  # hence the `|| true`.
  adb uninstall io.github.xexanos.ratatoskr >/dev/null 2>&1 || true
  adb install -r -g "$APP_APK"
}

# P1 happy-path spine + E2E-05 controls. Pause (verified on the speaker), then RESUME so that Stop
# is exercised from PLAYING - not only from the paused state - otherwise a stop path that assumes a
# prior pause would slip through. Pause-from-playing stays covered by p1-pause + the PAUSED_PLAYBACK
# assert; this adds the play->stop path back that moving Stop after Pause had removed.
cmd_p1() {
  # Locale canary first: proves the en-US pin actually resolves in the app UI (and survives the
  # clearState launch the spine opens with) before p1-spine can fail mid-run on a selector miss.
  # Lives here rather than drive_prep: its clearState wipe would destroy the signed-in end state
  # a standalone drive-p2 resume depends on.
  echo "run-e2e: locale canary (pinned en-US locale resolves in the app UI)"
  maestro test "$root/flows/p0-locale-canary.yaml"

  echo "run-e2e: running the P1 spine"
  maestro test "$root/flows/p1-spine.yaml" \
    -e SERVER_URL="https://localhost:8080" \
    -e ABS_USER="$E2E_ABS_USER" -e ABS_PASS="$E2E_ABS_PASS" \
    -e BOOK_TITLE="$E2E_BOOK_TITLE" -e SPEAKER_NAME="E2E Test Room" \
    -e CERT_FP="$E2E_CERT_FP"

  echo "run-e2e: asserting ABS progress (E2E-06)"
  bash "$root/scripts/assert-abs-progress.sh" "$ENV_FILE"

  echo "run-e2e: pausing playback (E2E-05 pause)"
  maestro test "$root/flows/p1-pause.yaml"
  echo "run-e2e: asserting the fake speaker actually paused (E2E-05)"
  bash "$root/scripts/assert-fake-transport.sh" PAUSED_PLAYBACK

  echo "run-e2e: resuming so Stop runs from PLAYING (E2E-05)"
  maestro test "$root/flows/p1-resume.yaml"
  echo "run-e2e: asserting the fake speaker is playing again (E2E-05)"
  bash "$root/scripts/assert-fake-transport.sh" PLAYING

  echo "run-e2e: stopping playback (E2E-05 stop)"
  maestro test "$root/flows/p1-stop.yaml"
  echo "run-e2e: asserting the fake speaker actually stopped (E2E-05)"
  bash "$root/scripts/assert-fake-transport.sh" STOPPED
}

cmd_drive() { drive_prep; cmd_p1; cmd_p2; }

# ---- P2 failure cases (test-concept.md §5, E2E-07/09/10) ----
#
# Ordering is deliberate:
#   E2E-10 first (ABS down/up) - no active session, so the only moving part is the library query.
#   E2E-09 next (speaker down/up) - starts and loses a session; recovery ends session-less.
#   E2E-07 last - sign-out ends the signed-in state everything else depends on.
cmd_p2() {
  echo "run-e2e: E2E-10 - stopping ABS (unreachable mid-run)"
  "${COMPOSE[@]}" stop abs
  maestro test "$root/flows/p2-abs-down.yaml"

  echo "run-e2e: E2E-10 - restarting ABS and waiting for it"
  "${COMPOSE[@]}" start abs
  wait_http "http://localhost:13378/status"
  maestro test "$root/flows/p2-abs-recovered.yaml" -e BOOK_TITLE="$E2E_BOOK_TITLE"

  echo "run-e2e: E2E-09 - starting a session to kill"
  maestro test "$root/flows/p2-session-start.yaml"
  echo "run-e2e: E2E-09 - stopping the fake speaker mid-session"
  "${COMPOSE[@]}" stop fake-sonos
  maestro test "$root/flows/p2-speaker-lost.yaml"
  echo "run-e2e: E2E-09 - restarting the fake speaker (comes back empty -> relinquish)"
  "${COMPOSE[@]}" start fake-sonos
  wait_fake_soap   # don't let a slow fake boot eat p2-session-relinquished's 30s window
  maestro test "$root/flows/p2-session-relinquished.yaml"

  echo "run-e2e: E2E-07 - signing out"
  maestro test "$root/flows/p2-signout.yaml"
}

# Teardown, volumes included - the session store and the generated certificate are deliberately
# throwaway, fresh per run.
#
# Compose interpolates the WHOLE file for `down` too, so the `:?` guards on the image refs and the
# keys abort it when nothing has loaded the environment - and the `|| true` below would then hide
# that, leaving the volumes in place. The next `up` generates a new SESSION_STORE_KEY, meets the
# previous run's store on the surviving volume, and the server refuses to start on a store it
# cannot decrypt. So load whatever this run recorded and fill the gaps with placeholders: tearing
# down cares about none of those values, and teardown has to work even for a run that failed
# before it wrote them.
cmd_down() {
  load_artifacts
  source_env "$ENV_FILE"
  SERVER_IMAGE="${SERVER_IMAGE:-none}" FAKE_SONOS_IMAGE="${FAKE_SONOS_IMAGE:-none}" \
    ABS_STREAMER_API_KEY="${ABS_STREAMER_API_KEY:-none}" SESSION_STORE_KEY="${SESSION_STORE_KEY:-none}" \
    "${COMPOSE[@]}" down -v || true
}


case "${1:-all}" in
  up) cmd_up ;;
  drive) cmd_drive ;;
  drive-p1) drive_prep; cmd_p1 ;;
  drive-p2) drive_prep; cmd_p2 ;;   # resume after a P1 run: needs the signed-in, stopped-session end state
  down) cmd_down ;;
  # Tear down on exit (success or failure) so a failed local `all` run never leaves the stack up
  # with host ports 8080/13378 bound, colliding with the next attempt. (CI runs up/drive/down as
  # separate steps and relies on the workflow's if: always() teardown instead.)
  all) trap cmd_down EXIT; cmd_up; cmd_drive ;;
  *) echo "usage: run-e2e.sh {up|drive|drive-p1|drive-p2|down|all}" >&2; exit 2 ;;
esac
