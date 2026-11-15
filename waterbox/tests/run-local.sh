#!/bin/bash
# Commercial games the owner has, run with the real ColecoVision BIOS from
# tests/roms-local (copied there by hand, never committed): native ==
# sandbox == a savestate saved and loaded before every frame, over 3600
# frames of the pad exercise (the keypad included, which starts each game).
# With the real ADAM ROMs there too (eos.rom, writer.rom), the same for the
# ADAM: SmartWriter with no media, typed on, and each game as the ADAM's
# cartridge. A game or a ROM that is absent is a SKIP, never a pass.
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
eos_sha1=ad3c20ef444f10af7ae8eb75c81e500d9b1bba3d
writer_sha1=d4aec4efe1431e56fe52d83baf9118542c525255
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
# three_runs <name> <work dir> <frames> <harness options...>: native ==
# sandbox == rerecord, and the program read its input on some frame
three_runs() {
	local name="$1" wd="$2" n="$3"
	shift 3
	"$nat/run-native" "$wd" --frames "$n" "$@" 2>/dev/null | digests > "$work/n.txt"
	"$nat/run-wbx" "$gst" "$wd" --frames "$n" "$@" 2>/dev/null | digests > "$work/b.txt"
	"$nat/run-wbx" "$gst" "$wd" --frames "$n" "$@" --rerecord 2>/dev/null | digests > "$work/r.txt"
	lag="$(sed -n 's/^lagFrames=//p' "$work/b.txt")"
	if grep -q "^frames=$n" "$work/b.txt" && cmp -s "$work/n.txt" "$work/b.txt" && cmp -s "$work/b.txt" "$work/r.txt" \
		&& [ "${lag:-$n}" -lt "$n" ]; then
		report "$name" PASS "$n frames, native == sandbox == rerecord, $lag lag frames"
	else
		report "$name" FAIL "the three runs differ, or the program never read its input (lag ${lag:-?})"
	fi
}
has() { [ -f "$local_dir/$1" ] && [ "$(sha1sum < "$local_dir/$1" | cut -d' ' -f1)" = "$2" ]; }
adam=0
if has eos.rom "$eos_sha1" && has writer.rom "$writer_sha1"; then adam=1; fi
adam_wd() { # dir: an ADAM with the real ROMs and no media
	rm -rf "$1"; mkdir -p "$1"
	cp "$bios" "$1/colecovision.rom"; cp "$local_dir/eos.rom" "$1/eos.rom"; cp "$local_dir/writer.rom" "$1/writer.rom"
	printf '{"machine":"adam"}' > "$1/settings"; printf '{}' > "$1/slots"
}

for entry in "${games[@]}"; do
	name="${entry%%|*}" sha1="${entry##*|}" file="$local_dir/${entry%%|*}"
	if [ ! -f "$file" ] || [ "$(sha1sum < "$file" | cut -d' ' -f1)" != "$sha1" ]; then
		report "$name" SKIP "not in tests/roms-local (SHA-1 $sha1)"; continue
	fi
	wd="$work/wd"; rm -rf "$wd"; mkdir -p "$wd"
	cp "$file" "$wd/game.col"; cp "$bios" "$wd/colecovision.rom"
	printf '{"cart":["game.col"]}' > "$wd/slots"
	three_runs "$name" "$wd" "$frames" --exercise
	if [ "$adam" = 1 ]; then
		# a cartridge alone on the ADAM starts the game
		adam_wd "$wd"; cp "$file" "$wd/game.col"; printf '{"adamcart":["game.col"]}' > "$wd/slots"
		three_runs "ADAM: $name" "$wd" "$frames" --exercise
	fi
done

if [ "$adam" = 0 ]; then
	report "ADAM" SKIP "needs tests/roms-local/eos.rom (SHA-1 $eos_sha1) and writer.rom (SHA-1 $writer_sha1)"
else
	# no media: SmartWriter, typed on from frame 60
	wd="$work/wd"; adam_wd "$wd"
	three_runs "ADAM: SmartWriter, typed on" "$wd" 1800 --exercise-keys
	typed="$(grep '^videoHash=' "$work/b.txt")"
	"$nat/run-wbx" "$gst" "$wd" --frames 1800 2>/dev/null | grep '^videoHash=' > "$work/idle.txt"
	if [ "$typed" != "$(cat "$work/idle.txt")" ]; then
		report "ADAM: SmartWriter, the keys" PASS "typing changes the picture"
	else
		report "ADAM: SmartWriter, the keys" FAIL "the picture is the one with nothing typed"
	fi
fi
echo; echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
