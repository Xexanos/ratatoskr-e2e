#!/usr/bin/env bash
# Generates the fixture audiobook that ABS scans: a single ~5-minute silent WAV under the
# Author/Title folder layout ABS expects. Silent is fine - E2E asserts control flow and the
# synced position (seconds), never audio; real audio is manual (test-concept.md §2). The long
# duration leaves room to seek/resume within the book (the seed sets an initial position at 120s).
#
# We emit a plain PCM WAV with python3's stdlib `wave` module - no ffmpeg (not on the ubuntu-24.04
# runner) and no committed binary. WAV is what the server repo's own integration fixture uses, so
# ABS/ffprobe reliably reads a duration from it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/fixtures/audiobooks/Test Author/Test Book"
out="$dir/track.wav"

mkdir -p "$dir"
if [ -f "$out" ]; then
  echo "make-fixture: fixture already present: $out"
  exit 0
fi

py="$(command -v python3 || command -v python || true)"
[ -n "$py" ] || { echo "make-fixture: python3 is required to generate the fixture WAV" >&2; exit 1; }

"$py" - "$out" <<'PY'
import sys, wave
path = sys.argv[1]
rate, seconds, channels = 8000, 300, 1   # 5 min mono; small, and >120s so the resume point fits
with wave.open(path, "wb") as w:
    w.setnchannels(channels)
    w.setsampwidth(2)  # 16-bit PCM
    w.setframerate(rate)
    w.writeframes(b"\x00\x00" * (rate * seconds * channels))  # silence
PY

echo "make-fixture: wrote $out ($(du -h "$out" | cut -f1))"
