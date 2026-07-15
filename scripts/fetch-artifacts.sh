#!/usr/bin/env bash
# Resolves and fetches the three pinned inputs for a run and records them in .e2e.artifacts.env:
#   - server image   (SERVER_IMAGE)      pinned by digest; from the server-image dispatch payload
#   - fake Sonos image (FAKE_SONOS_IMAGE) the fake's own :latest (or a pinned digest) - it is
#                                         published on its own cadence, not per server commit
#   - app APK         (APP_APK)           downloaded from the app's latest testing-* pre-release
#
# Inputs via env (CI sets these from the repository_dispatch payload; sensible defaults for a
# manual run): SERVER_IMAGE, FAKE_SONOS_IMAGE, APP_RELEASE_TAG.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
owner="${GHCR_OWNER:-xexanos}"
app_repo="${APP_REPO:-Xexanos/ratatoskr-app}"
artifacts="$root/artifacts"; mkdir -p "$artifacts"
out="$root/.e2e.artifacts.env"

SERVER_IMAGE="${SERVER_IMAGE:-ghcr.io/$owner/ratatoskr-server:latest}"

# The fake Sonos is a slowly-changing test dependency published on its OWN cadence (the server's
# fake-sonos.yml, path-filtered) as :latest + sha-<its-own-sha> - NOT per server commit, so there
# is no fake tag matching a given server sha. Track :latest by default; for fully reproducible
# runs, pin a digest (FAKE_SONOS_IMAGE=ghcr.io/<owner>/ratatoskr-fake-sonos@sha256:...) and bump it
# deliberately when the fake changes (test-concept.md §6).
FAKE_SONOS_IMAGE="${FAKE_SONOS_IMAGE:-ghcr.io/$owner/ratatoskr-fake-sonos:latest}"

echo "fetch-artifacts: pulling $SERVER_IMAGE"
docker pull "$SERVER_IMAGE"
echo "fetch-artifacts: pulling $FAKE_SONOS_IMAGE"
docker pull "$FAKE_SONOS_IMAGE"

# App APK: default to the newest testing-* pre-release (the app's rolling "latest" channel).
tag="${APP_RELEASE_TAG:-}"
if [ -z "$tag" ]; then
  tag="$(gh release list -R "$app_repo" --limit 30 --json tagName,isPrerelease \
    --jq '[.[] | select(.isPrerelease and (.tagName | startswith("testing-")))][0].tagName')"
fi
[ -n "$tag" ] || { echo "fetch-artifacts: no testing-* pre-release found in $app_repo" >&2; exit 1; }
echo "fetch-artifacts: downloading APK from $app_repo release $tag"
gh release download "$tag" -R "$app_repo" -p ratatoskr-minified.apk -D "$artifacts" --clobber
APP_APK="$artifacts/ratatoskr-minified.apk"
[ -f "$APP_APK" ] || { echo "fetch-artifacts: APK not downloaded" >&2; exit 1; }

cat > "$out" <<EOF
SERVER_IMAGE=$SERVER_IMAGE
FAKE_SONOS_IMAGE=$FAKE_SONOS_IMAGE
APP_APK=$APP_APK
APP_RELEASE_TAG=$tag
EOF
echo "fetch-artifacts: wrote $out"
