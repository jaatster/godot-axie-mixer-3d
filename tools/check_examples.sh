#!/usr/bin/env bash
# Headless error-count gate for the community examples.
# Fails on engine ERROR and SCRIPT ERROR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GODOT="${GODOT:-${GODOT_BIN:-}}"
if [[ -z "$GODOT" ]]; then
  if command -v godot >/dev/null 2>&1; then
    GODOT="$(command -v godot)"
  elif [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
    GODOT=/Applications/Godot.app/Contents/MacOS/Godot
  else
    echo "godot binary not found; set GODOT" >&2
    exit 2
  fi
fi

SCENES=(
  res://examples/minimal_from_genes.tscn
  res://examples/mixer_demo.tscn
  res://examples/collection_demo.tscn
  res://examples/spawner_demo.tscn
  res://examples/avatars_demo.tscn
  res://examples/bootstrap.tscn
)

fail=0
for scene in "${SCENES[@]}"; do
  log="$(mktemp)"
  name="$(basename "$scene" .tscn)"
  set +e
  "$GODOT" --headless --path "$ROOT" --scene "$scene" --quit-after 5 >"$log" 2>&1
  status=$?
  set -e
  errors="$(grep -c -E 'ERROR:|SCRIPT ERROR' "$log" || true)"
  echo "$name  exit=$status  ERROR=$errors"
  if [[ "$status" -ne 0 || "$errors" -ne 0 ]]; then
    grep -E 'ERROR:|SCRIPT ERROR' "$log" | sort | uniq -c | sort -rn | head -20
    fail=1
  fi
  rm -f "$log"
done

if [[ "$fail" -ne 0 ]]; then
  echo "EXAMPLE ERROR GATE FAILED"
  exit 1
fi
echo "EXAMPLE ERROR GATE PASSED"
