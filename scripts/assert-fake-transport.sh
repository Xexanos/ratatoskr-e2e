#!/usr/bin/env bash
# E2E-05 (stop): assert the fake Sonos speaker reached the expected AVTransport state, asked over
# SOAP directly - not via the app UI or the server's own report. This is what distinguishes a
# control that actually reached the speaker from an optimistic UI toggle: an app that shows
# "stopped" while the Stop SOAP never landed would still fail here.
# Usage: assert-fake-transport.sh EXPECTED_STATE   (e.g. STOPPED)
set -euo pipefail

expected="${1:?usage: assert-fake-transport.sh EXPECTED_STATE}"
FAKE_BASE="${FAKE_BASE:-http://localhost:1400}"
ctrl="$FAKE_BASE/MediaRenderer/AVTransport/Control"
soap='<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo></s:Body></s:Envelope>'

read_state() {
  curl -sS -X POST "$ctrl" \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -H 'SOAPACTION: "urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo"' \
    --data "$soap" 2>/dev/null \
    | sed -n 's:.*<CurrentTransportState>\([^<]*\)</CurrentTransportState>.*:\1:p'
}

# Poll briefly: the server issues Stop asynchronously as it tears the session down, so the fake
# may take a moment to settle.
for _ in $(seq 1 10); do
  state="$(read_state || true)"
  echo "assert-fake-transport: fake CurrentTransportState=${state:-<none>} (want $expected)"
  [ "$state" = "$expected" ] && { echo "assert-fake-transport: PASS - the speaker actually reached $expected"; exit 0; }
  sleep 1
done

echo "assert-fake-transport: FAIL - the fake speaker never reported $expected (last=${state:-<none>})" >&2
exit 1
