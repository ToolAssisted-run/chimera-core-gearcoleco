#!/bin/sh
# Applies patches/ to the extern/gearcoleco submodule's working tree. The
# submodule is pinned to unmodified upstream; meson runs this at every
# configure. The series is all or nothing: a tree that has the marker below
# is taken to have every patch already.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
sub="$root/extern/gearcoleco"

# a clone made without its submodule would make git apply the series to
# this repository instead: check that the submodule is really there
top="$(git -C "$sub" rev-parse --show-toplevel 2>/dev/null || true)"
[ "$top" = "$(cd "$sub" && pwd -P)" ] || {
	echo "extern/gearcoleco is not checked out: git submodule update --init" >&2; exit 1; }

marker="gearcoleco_input_read_hook"
if grep -q "$marker" "$sub/src/Input.cpp" 2>/dev/null; then
	exit 0
fi

for p in "$root"/patches/*.patch; do
	git -C "$sub" apply "$p"
	echo "applied $(basename "$p")"
done
