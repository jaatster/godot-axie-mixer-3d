#!/usr/bin/env bash
# Runs every parity gate of the port in order and stops at the first red one.
#
#   tools/run_gates.sh              # all gates
#   tools/run_gates.sh --no-render  # skip the GPU render gate (machine without a display)
#
# GODOT_BIN: Godot 4.7 executable (default: the macOS app bundle binary).
# GODOT:     the .app bundle used by tools/render_compare.sh.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
RENDER=1
for a in "$@"; do
	[[ "$a" == "--no-render" ]] && RENDER=0
done
cd "$REPO"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

headless_gate() { # name script
	printf '\n== %s\n' "$1"
	"$GODOT_BIN" --headless --path . -s "$2" >"$LOG" 2>&1
	local rc=$?
	grep -v -e "Leaked" -e "RID alloc" -e "PagedAllocator" -e "resources still" "$LOG" | tail -n 40
	if [[ $rc -ne 0 ]]; then
		printf 'GATE RED: %s (exit %d)\n' "$1" "$rc"
		exit 1
	fi
}

headless_gate "numeric oracle (tests/oracle_compare.gd)" tests/oracle_compare.gd
headless_gate "playable oracle (tests/playable_oracle_compare.gd)" tests/playable_oracle_compare.gd
headless_gate "behaviour tests (tests/run_tests.gd)" tests/run_tests.gd

if [[ -x tools/check_examples.sh ]]; then
	printf '\n== examples smoke (tools/check_examples.sh)\n'
	tools/check_examples.sh || { printf 'GATE RED: examples\n'; exit 1; }
fi

if [[ "$RENDER" == "1" ]]; then
	printf '\n== render oracle (tools/render_compare.sh)\n'
	tools/render_compare.sh --out /tmp/axie_render_gates || { printf 'GATE RED: render\n'; exit 1; }
fi

printf '\nALL GATES GREEN\n'
