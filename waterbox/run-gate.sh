#!/bin/bash
# The core test script: the sandboxed core (core.wbx) must give the same
# picture, sound, lag frames and memory as the native reference build (the
# same sources built for the host), frame by frame, and must survive a
# savestate saved and loaded around every frame ("rerecord").
#
# The programs it runs are this repository's own, built from source by
# tests/make-test-content.py: a ColecoVision cartridge (and the same with
# the Super Game Module), a stand-in for the ColecoVision BIOS, and stand-ins
# for the ADAM's EOS and SmartWriter ROMs that talk to the keyboard, a disk
# and a data pack. No Coleco ROM is needed or used. What they do not stand in
# for is in docs/PLAN.md ("What the tests do not prove").
#
# Usage: ./run-gate.sh [-n <native build dir>] [-g <guest build dir>]
# CHIMERA_ROOT=<a Chimera checkout with this package installed> adds the
# test through Chimera's engine.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
while getopts "n:g:" opt; do
	case "$opt" in
		n) nat="$OPTARG" ;;
		g) gst="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

[ -x "$nat/run-native" ] && [ -x "$nat/run-wbx" ] || {
	echo "native build missing: meson setup build/meson-native && ninja -C build/meson-native" >&2; exit 1; }
[ -f "$gst/core.wbx" ] || {
	echo "guest build missing: sh waterbox/setup-guest.sh && ninja -C build/meson-guest" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
content="$work/content"
python3 "$root/tests/make-test-content.py" "$content" || { echo "could not build the test programs" >&2; exit 1; }

digests() { grep -E '^(frames|vsync|videoHash|audioHash|audioSamples|lagFrames|domain\[)'; }
# what a turbo run can be held to: all but the whole-run picture hash, which
# a run that drew nothing for its first half cannot match
turboDigests() { grep -E '^(frames|vsync|tailVideoHash|audioHash|audioSamples|lagFrames|domain\[)'; }

ok=0
failed=0
report() { printf "%-30s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; SKIP) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-30s %-6s %s\n" "Check" "Result" "Detail"
printf "%-30s %-6s %s\n" "-----" "------" "------"

# A work dir holds what the sandbox would see mounted: the files under their
# mounted names, "slots" and "settings".
#   make_wd <dir> <settings JSON> <slots JSON> <file>=<content name>...
make_wd() {
	local wd="$1" settings="$2" slots="$3"
	shift 3
	rm -rf "$wd"
	mkdir -p "$wd"
	printf '%s' "$settings" > "$wd/settings"
	printf '%s' "$slots" > "$wd/slots"
	for pair in "$@"; do
		cp "$content/${pair#*=}" "$wd/${pair%%=*}"
	done
}
cv_wd() { # dir, settings, cartridge
	make_wd "$1" "$2" "{\"cart\":[\"$3\"]}" "colecovision.rom=free-os7.rom" "$3=$3"
}
adam_wd() { # dir, settings (machine added), slots, files...
	local wd="$1" settings="$2" slots="$3"
	shift 3
	make_wd "$wd" "{\"machine\":\"adam\"${settings:+,$settings}}" "$slots" \
		"colecovision.rom=free-os7.rom" "eos.rom=adam-eos.rom" "writer.rom=adam-writer.rom" "$@"
}
# the frame a frame-0 machine has (read from a dump at an address)
byte_at() { python3 -c "import sys; print(open(sys.argv[1],'rb').read()[int(sys.argv[2],0)])" "$1" "$2"; }

# equivalence + rerecord + turbo for one work dir and schedule, and the
# input-shaped check when the schedule drives anything
#   machine_legs <name> <wd> <idle args or -> <args...>
machine_legs() {
	local name="$1" wd="$2" idle="$3"
	shift 3
	if ! "$nat/run-native" "$wd" "$@" 2>"$work/err" | digests > "$work/nat.txt"; then
		report "$name:equivalence" FAIL "native runner error: $(head -1 "$work/err")"; return
	fi
	if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>"$work/err" | digests > "$work/box.txt"; then
		report "$name:equivalence" FAIL "sandbox runner error: $(head -1 "$work/err")"; return
	fi
	# a run that never started reports no frame; two such runs agree on nothing
	if ! grep -q '^frames=[1-9]' "$work/box.txt"; then
		report "$name:equivalence" FAIL "the sandboxed run reported no frame"; return
	fi
	local frames
	frames="$(sed -n 's/^frames=//p' "$work/box.txt")"
	cp "$work/box.txt" "$work/box.$name.txt"
	if cmp -s "$work/nat.txt" "$work/box.txt"; then
		report "$name:equivalence" PASS "$frames frames, native == sandbox ($(grep -c '^domain' "$work/box.txt") memory domains, $(sed -n 's/^lagFrames=//p' "$work/box.txt") lag frames)"
	else
		report "$name:equivalence" FAIL "$(diff "$work/nat.txt" "$work/box.txt" | tr '\n' ' ' | head -c 160)"; return
	fi

	if [ "$idle" != "-" ]; then
		# shellcheck disable=SC2086
		"$nat/run-wbx" "$gst/core.wbx" "$wd" $idle 2>/dev/null | digests > "$work/idle.txt"
		if cmp -s "$work/box.txt" "$work/idle.txt"; then
			report "$name:input-shaped" FAIL "the input schedule changed nothing"
		else
			report "$name:input-shaped" PASS "the input visibly shaped the machine"
		fi
	fi

	if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" --rerecord 2>/dev/null | digests > "$work/rr.txt"; then
		report "$name:savestate" FAIL "rerecord runner error"
	elif cmp -s "$work/box.txt" "$work/rr.txt"; then
		report "$name:savestate" PASS "saved and loaded around every frame: the same run"
	else
		report "$name:savestate" FAIL "$(diff "$work/box.txt" "$work/rr.txt" | tr '\n' ' ' | head -c 160)"
	fi

	# Turbo: nothing drawn for the first half; the machine, the sound and the
	# second half's pictures must be what they would have been. The whole-run
	# picture hash must differ, or nothing was skipped at all.
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>/dev/null > "$work/tnorm.raw"
	if "$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" --turbo 2>/dev/null > "$work/tturbo.raw"; then
		turboDigests < "$work/tnorm.raw" > "$work/tnorm.txt"
		turboDigests < "$work/tturbo.raw" > "$work/tturbo.txt"
		if ! cmp -s "$work/tnorm.txt" "$work/tturbo.txt"; then
			report "$name:turbo" FAIL "$(diff "$work/tnorm.txt" "$work/tturbo.txt" | tr '\n' ' ' | head -c 160)"
		elif [ "$(grep -m1 '^videoHash=' "$work/tnorm.raw")" = "$(grep -m1 '^videoHash=' "$work/tturbo.raw")" ]; then
			report "$name:turbo" FAIL "the turbo run drew every frame: nothing was skipped"
		else
			report "$name:turbo" PASS "half the frames undrawn, the same machine and the same later pictures"
		fi
	else
		report "$name:turbo" FAIL "turbo runner error"
	fi
}

# one run in both flavors that must agree
#   equiv_leg <name> <wd> <args...>
equiv_leg() {
	local name="$1" wd="$2"
	shift 2
	"$nat/run-native" "$wd" "$@" 2>/dev/null | digests > "$work/en.txt"
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>/dev/null | digests > "$work/eb.txt"
	if ! grep -q '^frames=[1-9]' "$work/eb.txt"; then
		report "$name" FAIL "the sandboxed run reported no frame"
	elif cmp -s "$work/en.txt" "$work/eb.txt"; then
		report "$name" PASS "native == sandbox"
	else
		report "$name" FAIL "$(diff "$work/en.txt" "$work/eb.txt" | tr '\n' ' ' | head -c 160)"
	fi
}

# a run of one work dir in both flavors that must agree, and must not be the
# run of another work dir or schedule
#   differs_leg <name> <what it must not be> <wd> <other wd> <args...>
differs_leg() {
	local name="$1" unlike="$2" wd="$3" other="$4"
	shift 4
	"$nat/run-native" "$wd" "$@" 2>/dev/null | digests > "$work/dn.txt"
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>/dev/null | digests > "$work/db.txt"
	"$nat/run-wbx" "$gst/core.wbx" "$other" "$@" 2>/dev/null | digests > "$work/do.txt"
	if ! grep -q '^frames=[1-9]' "$work/db.txt"; then
		report "$name" FAIL "the sandboxed run reported no frame"
	elif ! cmp -s "$work/dn.txt" "$work/db.txt"; then
		report "$name" FAIL "$(diff "$work/dn.txt" "$work/db.txt" | tr '\n' ' ' | head -c 160)"
	elif cmp -s "$work/db.txt" "$work/do.txt"; then
		report "$name" FAIL "the same machine as $unlike: the setting did not reach the guest"
	else
		report "$name" PASS "native == sandbox, and not the machine $unlike makes"
	fi
}

# ------------------------------------------------------------ the ColecoVision
ex=(--frames 600 --exercise --exercise-pad2 --wiggle-axes)
cv_wd "$work/cv" '{}' cv-test.col
machine_legs cv "$work/cv" "--frames 600" "${ex[@]}"

# the program reads its controllers on three frames of four: those are the
# frames that are not lag frames
lag="$(sed -n 's/^lagFrames=//p' "$work/box.cv.txt")"
if [ -n "$lag" ] && [ "$lag" -ge 140 ] && [ "$lag" -le 160 ]; then
	report "cv:lag" PASS "$lag of 600 frames read no controller (the program skips every fourth)"
else
	report "cv:lag" FAIL "lagFrames=${lag:-missing}; the program reads on 3 frames of 4, so about 150 were expected"
fi

# the Super Game Module: the module's RAM is written only by the SGM program
cv_wd "$work/sgm" '{}' cv-sgm.col
machine_legs sgm "$work/sgm" - "${ex[@]}"
if [ "$(grep '^domain\[SGM RAM\]' "$work/box.sgm.txt")" != "$(grep '^domain\[SGM RAM\]' "$work/box.cv.txt")" ] \
	&& [ "$(grep '^audioHash' "$work/box.sgm.txt")" != "$(grep '^audioHash' "$work/box.cv.txt")" ]; then
	report "sgm:used" PASS "the module's RAM and sound differ from the plain cartridge's"
else
	report "sgm:used" FAIL "the SGM program left the module's RAM or sound as the plain one does"
fi

# the settings that make another machine
cv_wd "$work/f18a" '{"videoChip":"f18a"}' cv-test.col
differs_leg settings:videoChip "the TMS9918A" "$work/f18a" "$work/cv" --frames 300 --exercise
if "$nat/run-native" "$work/f18a" --frames 2 2>&1 >/dev/null | grep -q 'video chip F18A'; then
	report settings:videoChip:f18a PASS "the machine reports the F18A"
else
	report settings:videoChip:f18a FAIL "the machine does not report the F18A"
fi
cv_wd "$work/pal" '{"region":"pal"}' cv-test.col
differs_leg settings:region "NTSC" "$work/pal" "$work/cv" --frames 300 --exercise
if "$nat/run-wbx" "$gst/core.wbx" "$work/pal" --frames 2 2>/dev/null | grep -q '^vsync=3579545/71364$'; then
	report settings:region:rate PASS "PAL runs at 3579545/71364 frames a second"
else
	report settings:region:rate FAIL "PAL does not report 3579545/71364"
fi
cv_wd "$work/sprites" '{"overscan":"full320"}' cv-test.col
if "$nat/run-wbx" "$gst/core.wbx" "$work/sprites" --frames 10 --screenshot "$work/os.tga" >/dev/null 2>&1 \
	&& python3 -c "import sys; d=open(sys.argv[1],'rb').read(18); sys.exit(0 if (d[12]|d[13]<<8, d[14]|d[15]<<8) == (320, 240) else 1)" "$work/os.tga"; then
	report settings:overscan PASS "the full border makes a 320x240 picture"
else
	report settings:overscan FAIL "the full border did not make a 320x240 picture"
fi

# Reset: pressed once, the machine is another one from that frame on
equiv_leg reset "$work/cv" --frames 300 --exercise --reset-at 150
"$nat/run-wbx" "$gst/core.wbx" "$work/cv" --frames 300 --exercise --reset-at 150 2>/dev/null | digests > "$work/r1.txt"
"$nat/run-wbx" "$gst/core.wbx" "$work/cv" --frames 300 --exercise 2>/dev/null | digests > "$work/r0.txt"
if cmp -s "$work/r1.txt" "$work/r0.txt"; then
	report reset:effect FAIL "pressing Reset changed nothing"
else
	report reset:effect PASS "pressing Reset on frame 150 changes the run"
fi

# ------------------------------------------------------------ the ADAM
media='{"disk1":["adam-test.dsk"],"datapack1":["adam-test.ddp"]}'
adam_wd "$work/adam" '' "$media" adam-test.dsk=adam-test.dsk adam-test.ddp=adam-test.ddp
exa=(--frames 900 --exercise --exercise-keys)
machine_legs adam "$work/adam" "--frames 900" "${exa[@]}"

# the keyboard, the disk and the data pack really answered the program
mkdir -p "$work/sd.box" "$work/sd.nat"
"$nat/run-wbx" "$gst/core.wbx" "$work/adam" "${exa[@]}" --savedata-out "$work/sd.box" \
	--dump-domain "Main RAM" "$work/adam.ram" >/dev/null 2>&1
"$nat/run-native" "$work/adam" "${exa[@]}" --savedata-out "$work/sd.nat" >/dev/null 2>&1
keys="$(byte_at "$work/adam.ram" 0x8008)"
disk="$(byte_at "$work/adam.ram" 0x8020)"
ddp="$(byte_at "$work/adam.ram" 0x8030)"
if [ "${keys:-0}" -gt 20 ]; then
	report adam:keyboard PASS "the program read $keys keys through ADAMnet"
else
	report adam:keyboard FAIL "the program read ${keys:-no} keys"
fi
"$nat/run-wbx" "$gst/core.wbx" "$work/adam" --frames 900 --exercise --dump-domain "Main RAM" "$work/adam-nokeys.ram" >/dev/null 2>&1
if [ "$(byte_at "$work/adam-nokeys.ram" 0x8008)" = 0 ]; then
	report adam:keyboard:control PASS "with no key pressed the program read none"
else
	report adam:keyboard:control FAIL "keys arrived that nobody pressed"
fi
if [ "${disk:-0}" -gt 5 ] && [ "${ddp:-0}" -gt 5 ]; then
	report adam:media PASS "$disk blocks from disk 1 and $ddp from data pack 1 came back"
else
	report adam:media FAIL "disk ${disk:-?} and data pack ${ddp:-?} blocks came back"
fi
nsd="$(find "$work/sd.box" -type f | wc -l)"
if [ "$nsd" = 2 ] && diff -r "$work/sd.nat" "$work/sd.box" >/dev/null \
	&& ! cmp -s "$work/sd.box/adam-test.dsk" "$content/adam-test.dsk" \
	&& ! cmp -s "$work/sd.box/adam-test.ddp" "$content/adam-test.ddp"; then
	report savedata:adam PASS "the written disk and data pack come out, native == sandbox, changed from the images put in"
else
	report savedata:adam FAIL "$nsd files; native and sandbox differ, or the images did not change"
fi
# what comes out goes back in: the written disk in the drive's slot
adam_wd "$work/adam2" '' '{"disk1":["adam-test.dsk"]}' adam-test.dsk=adam-test.dsk
adam_wd "$work/adam3" '' '{"disk1":["adam-test.dsk"]}'
cp "$work/sd.box/adam-test.dsk" "$work/adam3/adam-test.dsk"
differs_leg savedata:adam:back "the unwritten disk" "$work/adam3" "$work/adam2" --frames 300

equiv_leg adam:computer-reset "$work/adam" "${exa[@]}" --computer-reset-at 400
"$nat/run-wbx" "$gst/core.wbx" "$work/adam" "${exa[@]}" --computer-reset-at 400 2>/dev/null | digests > "$work/c1.txt"
if cmp -s "$work/c1.txt" "$work/box.adam.txt"; then
	report adam:computer-reset:effect FAIL "Computer Reset changed nothing"
else
	report adam:computer-reset:effect PASS "Computer Reset on frame 400 changes the run"
fi

# a cartridge alone: the ADAM starts it as a game, through OS-7 (here, the
# stand-in) and the cartridge's start address
adam_wd "$work/adamcart" '' '{"adamcart":["cv-test.col"]}' cv-test.col=cv-test.col
machine_legs adamcart "$work/adamcart" - --frames 600 --exercise
"$nat/run-wbx" "$gst/core.wbx" "$work/adamcart" --frames 120 --dump-domain "Main RAM" "$work/adamcart.ram" >/dev/null 2>&1
n="$(byte_at "$work/adamcart.ram" 0x7004)"
if [ "${n:-0}" -ge 115 ] && [ "${n:-0}" -le 120 ]; then
	report adamcart:runs PASS "the cartridge counted $n frames of 120 in the ADAM's RAM"
else
	report adamcart:runs FAIL "the cartridge's frame count is ${n:-unreadable} after 120 frames"
fi

# ------------------------------------------------------------ what a load refuses
cv_wd "$work/nobios" '{}' cv-test.col
rm -f "$work/nobios/colecovision.rom"
if "$nat/run-wbx" "$gst/core.wbx" "$work/nobios" --frames 2 2>&1 >/dev/null | grep -q 'error.no_firmware.colecovision.rom'; then
	report refuse:no-bios PASS "without the BIOS the load fails and names it"
else
	report refuse:no-bios FAIL "the load did not fail on the missing BIOS"
fi
adam_wd "$work/badmedia" '' '{"disk1":["bad.dsk"]}'
head -c 1000 "$content/adam-test.dsk" > "$work/badmedia/bad.dsk"
if "$nat/run-wbx" "$gst/core.wbx" "$work/badmedia" --frames 2 2>&1 >/dev/null | grep -q 'error.media_rejected'; then
	report refuse:bad-media PASS "a disk of the wrong size is refused"
else
	report refuse:bad-media FAIL "a disk of the wrong size was not refused"
fi
cv_wd "$work/badsave" '{}' cv-test.col
printf '{"cart":["cv-test.col"],"savedata":["battery.sav"]}' > "$work/badsave/slots"
head -c 32 /dev/zero > "$work/badsave/battery.sav"
if "$nat/run-wbx" "$gst/core.wbx" "$work/badsave" --frames 2 2>&1 >/dev/null | grep -q 'error.savedata_unused'; then
	report refuse:savedata PASS "save data for a cartridge that keeps none is refused"
else
	report refuse:savedata FAIL "save data for a cartridge that keeps none was accepted"
fi

# ------------------------------------------------------------ Chimera's engine
# Each read of the controls reaches Chimera as it happens (a Lua script's
# event.oninputpoll runs there): at least one for every frame that is not a
# lag frame, and counting them moves nothing. Needs CHIMERA_ROOT, a Chimera
# checkout with this core's package installed in it.
runner="${CHIMERA_ROOT:-}/build/meson-linux/chimera-run"
package="${CHIMERA_ROOT:-}/build/Cores/gearcoleco.chimeraCore"
if [ -n "${CHIMERA_ROOT:-}" ] && [ -x "$runner" ] && [ -f "$package" ]; then
	cart="$content/cv-test.col"
	fw="colecovision.rom=$content/free-os7.rom"
	# a game runs only in a project: one with no input, to record 300 idle
	# frames in, then one of those frames
	"$runner" --new-project "$work/none.chimeraProject" "$package" "$cart" --firmware "$fw" > "$work/none.make.log" 2>&1
	"$runner" --project "$work/none.chimeraProject" "$package" --files "$content" --firmware "$fw" \
		--frames 300 --record "$work/idle.txt" > "$work/idle.log" 2>&1
	"$runner" --new-project "$work/e.chimeraProject" "$package" "$cart" "$work/idle.txt" --firmware "$fw" > "$work/e.make.log" 2>&1
	"$runner" --project "$work/e.chimeraProject" "$package" --files "$content" --firmware "$fw" \
		--dump "Work RAM=$work/plain.ram" --meta "$work/plain.meta" > "$work/plain.log" 2>&1
	"$runner" --project "$work/e.chimeraProject" "$package" --files "$content" --firmware "$fw" --count-input-polls \
		--dump "Work RAM=$work/polls.ram" --meta "$work/polls.meta" > "$work/polls.log" 2>&1
	polls=$(sed -n 's/^inputPolls=//p' "$work/polls.meta" 2> /dev/null)
	lags=$(sed -n 's/^lagFrames=//p' "$work/polls.meta" 2> /dev/null)
	frames=$(sed -n 's/^frames=//p' "$work/polls.meta" 2> /dev/null)
	if [ "${polls:-none}" != none ] && [ "${frames:-0}" = 300 ] && [ "${lags:-300}" -lt 300 ] \
		&& [ "${polls:-0}" -ge $(( 300 - ${lags:-300} )) ] && [ -s "$work/plain.ram" ] && cmp -s "$work/plain.ram" "$work/polls.ram"; then
		report "engine:input-polls" PASS "$polls reads of the controllers in 300 frames, $lags lag frames; Work RAM is the run's without counting"
	else
		report "engine:input-polls" FAIL "inputPolls=${polls:-missing} frames=${frames:-?} lagFrames=${lags:-?}, or counting moved Work RAM: $(tail -1 "$work/polls.log" 2> /dev/null)"
	fi
else
	report "engine:input-polls" SKIP "needs CHIMERA_ROOT with build/meson-linux/chimera-run and build/Cores/gearcoleco.chimeraCore"
fi

echo ""
echo "$ok ok, $failed failed"
[ "$failed" -gt 0 ] && exit 1
exit 0
