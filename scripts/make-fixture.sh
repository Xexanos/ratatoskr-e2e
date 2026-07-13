#!/usr/bin/env bash
# Generates the fixture audiobook that ABS scans: a single ~5-minute silent MP3 under the
# Author/Title folder layout ABS expects. Silent is fine - E2E asserts control flow and the
# synced position (seconds), never audio; real audio is manual (test-concept.md §2). The long
# duration leaves room to seek/resume within the book.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/fixtures/audiobooks/Test Author/Test Book"
out="$dir/track.mp3"

mkdir -p "$dir"
if [ -f "$out" ]; then
  echo "make-fixture: fixture already present: $out"
  exit 0
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "make-fixture: ffmpeg is required to generate the fixture audiobook." >&2
  echo "  GitHub ubuntu runners have it preinstalled; locally install ffmpeg (apt/brew)." >&2
  exit 1
fi

ffmpeg -nostdin -hide_banner -loglevel error \
  -f lavfi -i anullsrc=r=44100:cl=mono -t 300 \
  -c:a libmp3lame -b:a 32k \
  -metadata title="Test Book" -metadata artist="Test Author" -metadata album="Test Book" \
  "$out"

echo "make-fixture: wrote $out"
