#!/bin/bash
# The frontend test script: the Gearcoleco package in Chimera's window, run
# headless (no display), through a project made with chimera-run, as a
# person opens a game. Each run's memory must be byte for byte the native
# reference's after the same frames:
#   cart:frontend      a ColecoVision cartridge, nothing pressed
#   input:frontend     the same, holding two of player 1's buttons
#   settings:region    a PAL project (a setting that makes another machine)
#   adam:frontend      an ADAM project with a disk and a data pack
# and keybinds: the package's bindings are the machine's when nobody changed
# them. The programs and firmware are this repository's own
# (tests/make-test-content.py); no Coleco ROM is used.
#
# Usage: ./run-frontend.sh [--chimera-root <path>] [--frames N]
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
frames=300
chimera_root=""
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera-root) chimera_root="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ -z "$chimera_root" ] && [ -d "$root/../chimera" ]; then
	chimera_root="$root/../chimera"
fi
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || {
	echo "chimera checkout not found; pass --chimera-root <path>" >&2; exit 1; }
chimera_root="$(cd "$chimera_root" && pwd)"

chimera_exe="$chimera_root/build/meson-linux/source/ui/chimera"
crun="$chimera_root/build/meson-linux/chimera-run"
package="$chimera_root/build/Cores/gearcoleco.chimeraCore"
rn="$root/build/meson-native/run-native"
[ -x "$chimera_exe" ] || { echo "Chimera not built: $chimera_exe" >&2; exit 1; }
[ -x "$crun" ] || { echo "chimera-run not built: $crun" >&2; exit 1; }
[ -f "$package" ] || { echo "package not installed: $package (run waterbox/build-package.sh)" >&2; exit 1; }
[ -x "$rn" ] || { echo "native reference not built" >&2; exit 1; }

work="$here/work"
rm -rf "$work"
mkdir -p "$work"
content="$work/content"
python3 "$root/tests/make-test-content.py" "$content" || exit 1
os7="$content/free-os7.rom"

# Chimera's window, run headless: the cores installed in the checkout, its
# settings, cache and recovery files the run's own, and nothing carried over
# from a Chimera installed on this machine
export ALSOFT_DRIVERS=null CHIMERA_CORES_DIR="$chimera_root/build/Cores" CHIMERA_QT_CACHE="$work/qt-cache" CHIMERA_QT_RECOVERY="$work/qt-recovery" \
	CHIMERA_QT_HASHES="$work/qt-file-hashes.txt" CHIMERA_QT_CHIMERA_SETTINGS="$work/no-chimera-config.ini"

ok=0
failed=0
report() { printf "%-28s %-9s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-28s %-9s %s\n" "Check" "Result" "Detail"
printf "%-28s %-9s %s\n" "-----" "------" "------"

# the window's settings: the firmware, remembered as if chosen by hand
cv_cfg="$work/settings.cv.json"
adam_cfg="$work/settings.adam.json"
python3 "$here/settings-config.py" "$cv_cfg" "{\"colecovision.rom\": \"$os7\"}"
python3 "$here/settings-config.py" "$adam_cfg" "{\"colecovision.rom\": \"$os7\", \"eos.rom\": \"$content/adam-eos.rom\", \"writer.rom\": \"$content/adam-writer.rom\"}"
cv_fw=(--firmware "colecovision.rom=$os7")
adam_fw=("${cv_fw[@]}" --firmware "eos.rom=$content/adam-eos.rom" --firmware "writer.rom=$content/adam-writer.rom")

# make_project <tag> <settings JSON> <chimera-run --new-project arguments...>
# The project sits beside its files, where the window looks for them.
make_project() {
	local tag="$1" settings="$2"
	shift 2
	"$crun" --new-project "$content/$tag.chimeraProject" "$package" "$@" --settings "$settings" \
		> "$work/$tag.make.log" 2>&1 && [ -f "$content/$tag.chimeraProject" ]
}

# run_window <tag> <config> <system> <domain> <hold>
run_window() {
	local tag="$1" cfg="$2" system="$3" domain="$4" hold="${5:-}"
	local job="$work/job.$tag.txt"
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\nhold=%s\nsystem=%s\ndomain=%s\n' \
		"$frames" "$work/$tag.ram.bin" "$work/$tag.meta.txt" "$hold" "$system" "$domain" > "$job"
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$cfg" "--core=$package" \
		"--lua=$here/frontend-ram.lua" "--project=$content/$tag.chimeraProject" ) > "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}

# native_ram <tag> <settings JSON> <slots JSON> <domain> <file>=<content>... [-- <run-native options>]
native_ram() {
	local tag="$1" settings="$2" slots="$3" domain="$4"
	shift 4
	local wd="$work/native.$tag"
	mkdir -p "$wd"
	printf '%s' "$settings" > "$wd/settings"
	printf '%s' "$slots" > "$wd/slots"
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		cp "$content/${1#*=}" "$wd/${1%%=*}"
		shift
	done
	[ "${1:-}" = "--" ] && shift
	"$rn" "$wd" --frames "$frames" "$@" --dump-domain "$domain" "$work/native.$tag.ram.bin" > "$work/native.$tag.txt" 2>&1
}

# leg <name> <tag> <detail>: compare the window's dump with the native one
compare() {
	local name="$1" tag="$2" detail="$3"
	if cmp -s "$work/native.$tag.ram.bin" "$work/$tag.ram.bin"; then
		report "$name" PASS "$detail"
	else
		report "$name" FAIL "the memory differs from the native reference"
	fi
}

cv_files=("colecovision.rom=free-os7.rom" "cv-test.col=cv-test.col")
cv_slots='{"cart":["cv-test.col"]}'

# --- a cartridge, nothing pressed ---
if ! make_project base '{}' "$content/cv-test.col" "${cv_fw[@]}"; then
	report "cart:frontend" FAIL "no project made (see tests/work/base.make.log)"
elif ! native_ram base '{}' "$cv_slots" "Work RAM" "${cv_files[@]}"; then
	report "cart:frontend" FAIL "native runner error (see tests/work/native.base.txt)"
elif ! run_window base "$cv_cfg" CV "Work RAM"; then
	report "cart:frontend" FAIL "no OK from the window (see tests/work/base.log)"
else
	compare "cart:frontend" base "$frames frames, Work RAM identical to the native reference"
fi

# --- input through the window: player 1's Right and Left Button held; the
# native twin holds the same two (wire 4 and 5) ---
if ! make_project hold '{}' "$content/cv-test.col" "${cv_fw[@]}"; then
	report "input:frontend" FAIL "no project made (see tests/work/hold.make.log)"
elif ! native_ram hold '{}' "$cv_slots" "Work RAM" "${cv_files[@]}" -- --hold 4,5; then
	report "input:frontend" FAIL "native runner error"
elif ! run_window hold "$cv_cfg" CV "Work RAM" "P1 Right,P1 Left Button"; then
	report "input:frontend" FAIL "no OK from the window (see tests/work/hold.log)"
elif cmp -s "$work/hold.ram.bin" "$work/base.ram.bin"; then
	report "input:frontend" FAIL "holding the buttons changed nothing"
else
	compare "input:frontend" hold "P1 Right and Left Button held through the window: the native twin's RAM"
fi

# --- a setting that makes another machine: PAL ---
if ! make_project pal '{"region":"pal"}' "$content/cv-test.col" "${cv_fw[@]}"; then
	report "settings:region" FAIL "no project made (see tests/work/pal.make.log)"
elif ! native_ram pal '{"region":"pal"}' "$cv_slots" "Work RAM" "${cv_files[@]}"; then
	report "settings:region" FAIL "native runner error"
elif ! run_window pal "$cv_cfg" CV "Work RAM"; then
	report "settings:region" FAIL "no OK from the window (see tests/work/pal.log)"
elif cmp -s "$work/pal.ram.bin" "$work/base.ram.bin"; then
	report "settings:region" FAIL "the PAL machine's memory is the NTSC one's"
else
	compare "settings:region" pal "region=pal reached the machine: Work RAM is the native PAL run's, not the NTSC one's"
fi

# --- the ADAM, with a disk and a data pack ---
adam_settings='{"machine":"adam"}'
if ! make_project adam "$adam_settings" --file "disk1=$content/adam-test.dsk" --file "datapack1=$content/adam-test.ddp" "${adam_fw[@]}"; then
	report "adam:frontend" FAIL "no project made (see tests/work/adam.make.log)"
elif ! native_ram adam "$adam_settings" '{"disk1":["adam-test.dsk"],"datapack1":["adam-test.ddp"]}' "Main RAM" \
	"colecovision.rom=free-os7.rom" "eos.rom=adam-eos.rom" "writer.rom=adam-writer.rom" \
	"adam-test.dsk=adam-test.dsk" "adam-test.ddp=adam-test.ddp"; then
	report "adam:frontend" FAIL "native runner error"
elif ! run_window adam "$adam_cfg" ADAM "Main RAM"; then
	report "adam:frontend" FAIL "no OK from the window (see tests/work/adam.log)"
else
	compare "adam:frontend" adam "$frames frames of the ADAM with a disk and a data pack: Main RAM identical to the native reference"
fi

# --- the bindings the package ships are the machine's when nobody changed them ---
run_controls() { # tag, config, controller name, the project it opens
	local tag="$1" cfg="$2" name="$3" job="$work/job.$1.txt"
	printf 'out=%s/%s.controls.json\nmeta=%s/%s.meta.txt\n' "$work" "$tag" "$work" "$tag" > "$job"
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$cfg" "--core=$package" \
		"--lua=$here/dump-controls.lua" "--project=$content/$4.chimeraProject" ) > "$work/$tag.log" 2>&1
	if [ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt" \
		&& python3 "$here/check-keybinds.py" "$work/$tag.controls.json" "$wb/default_keybinds.json" "$name" > "$work/$tag.txt" 2>&1; then
		report "keybinds:$tag" PASS "$(cat "$work/$tag.txt")"
	else
		report "keybinds:$tag" FAIL "$(head -1 "$work/$tag.txt" 2>/dev/null) (see tests/work/$tag.log)"
	fi
}
run_controls cv "$cv_cfg" "ColecoVision Controls" base
run_controls adam "$adam_cfg" "ADAM Controls" adam

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
