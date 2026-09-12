#!/usr/bin/env bash
# Runs tests/render_compare.gd in a hidden background Godot (needs a GPU; --headless has none)
# without stealing focus, waits for it to finish and prints its log.
#
#   tools/render_compare.sh [fixture_substring] [--out DIR]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app}"
OUT="/tmp/axie_render"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	if [[ "${args[$i]}" == "--out" && $((i + 1)) -lt ${#args[@]} ]]; then
		OUT="${args[$((i + 1))]}"
	fi
done
mkdir -p "$OUT"
rm -f "$OUT/done.txt"
LOG="$OUT/godot.log"
: >"$LOG"
open -g -j -n -a "$GODOT" --args --path "$REPO" -s tests/render_compare.gd \
	--resolution 320x200 --position 4000,4000 --log-file "$LOG" -- --out "$OUT" ${args[@]+"${args[@]}"}
for ((t = 0; t < 900; t++)); do
	[[ -f "$OUT/done.txt" ]] && break
	sleep 1
done
if [[ ! -f "$OUT/done.txt" ]]; then
	echo "render_compare: timed out" >&2
	exit 2
fi
grep -v -e "Leaked" -e "RID alloc" -e "PagedAllocator" -e "resources still" -e "^   " "$LOG" || true
failures="$(head -n 1 "$OUT/done.txt")"
exit "$([[ "$failures" == "0" ]] && echo 0 || echo 1)"
