#!/bin/bash
# Commercial games the owner has, run with the real ColecoVision BIOS from
# tests/roms-local (copied there by hand, never committed): native ==
# sandbox == a savestate saved and loaded before every frame, over 3600
# frames of the pad exercise (the keypad included, which starts each game).
# A game or the BIOS that is absent is a SKIP, never a pass.
#
# Usage: ./run-local.sh   (after building build/meson-native and build/meson-guest)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest/core.wbx"
local_dir="$root/tests/roms-local"
bios="$local_dir/Coleco_Bios.bin"
bios_sha1=45bedc4cbdeac66c7df59e9e599195c778d86a92
frames=3600
games=(
	"Carnival (1982) [a1].col|41e08352df00d4ea4f8b52ce2a81cd0c1581ce93"
	"Oil's Well (1984)(Sierra On-Line).bin|779e43f183dbdb692dc26ae41dde6b35891f8f8b"
)

ok=0; failed=0
report() { printf "%-40s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; FAIL) failed=$((failed+1)) ;; esac; }
digests() { grep -E '^(frames|vsync|videoHash|audioHash|audioSamples|lagFrames|domain\[)'; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ ! -f "$bios" ] || [ "$(sha1sum < "$bios" | cut -d' ' -f1)" != "$bios_sha1" ]; then
	report "bios" SKIP "needs tests/roms-local/Coleco_Bios.bin, SHA-1 $bios_sha1"
	echo; echo "$ok ok, $failed failed"; exit 0
fi
for entry in "${games[@]}"; do
	name="${entry%%|*}" sha1="${entry##*|}" file="$local_dir/${entry%%|*}"
	if [ ! -f "$file" ] || [ "$(sha1sum < "$file" | cut -d' ' -f1)" != "$sha1" ]; then
		report "$name" SKIP "not in tests/roms-local (SHA-1 $sha1)"; continue
	fi
	wd="$work/wd"; rm -rf "$wd"; mkdir -p "$wd"
	cp "$file" "$wd/game.col"; cp "$bios" "$wd/colecovision.rom"
	printf '{"cart":["game.col"]}' > "$wd/slots"
	args=(--frames "$frames" --exercise)
	"$nat/run-native" "$wd" "${args[@]}" 2>/dev/null | digests > "$work/n.txt"
	"$nat/run-wbx" "$gst" "$wd" "${args[@]}" 2>/dev/null | digests > "$work/b.txt"
	"$nat/run-wbx" "$gst" "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/r.txt"
	lag="$(sed -n 's/^lagFrames=//p' "$work/b.txt")"
	if grep -q "^frames=$frames" "$work/b.txt" && cmp -s "$work/n.txt" "$work/b.txt" && cmp -s "$work/b.txt" "$work/r.txt" \
		&& [ "${lag:-$frames}" -lt "$frames" ]; then
		report "$name" PASS "$frames frames, native == sandbox == rerecord, $lag lag frames"
	else
		report "$name" FAIL "the three runs differ, or the game never read its controllers (lag ${lag:-?})"
	fi
done
echo; echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
