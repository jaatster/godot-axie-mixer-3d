#!/usr/bin/env bash
# Real-GPU regression for Mystic surface/particle HDR and animated shader phases.
# tools/mystic_hdr.sh [forward_plus|mobile] [output_directory]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="${1:-forward_plus}"
OUT="${2:-/tmp/axie_mystic_hdr_${RENDERER}}"
GODOT="${GODOT:-/Applications/Godot.app}"
case "$RENDERER" in forward_plus|mobile) ;; *) echo "Use forward_plus or mobile" >&2; exit 2 ;; esac
mkdir -p "$OUT"
rm -f "$OUT/done.txt"
open -g -j -n -a "$GODOT" --args --path "$REPO" --rendering-method "$RENDERER" \
  -s tests/test_mystic_hdr.gd --resolution 320x200 --position 4000,4000 \
  --log-file "$OUT/godot.log" -- --out "$OUT" --hdr2d
for ((i=0; i<90; i++)); do
  if [[ -f "$OUT/done.txt" ]]; then
    cat "$OUT/godot.log"
    [[ "$(cat "$OUT/done.txt")" == "0" ]]
    exit $?
  fi
  sleep 1
done
cat "$OUT/godot.log"
echo "Mystic HDR test timed out" >&2
exit 2
