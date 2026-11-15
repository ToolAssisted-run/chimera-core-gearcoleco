# Building chimera-core-gearcoleco

## Requirements

Linux on x86_64 or aarch64 (CI uses Ubuntu 24.04: GCC 13, meson 1.3), with
`meson ninja-build build-essential python3`, and a Chimera checkout with
miniBox's C++ guest toolchain:

```
git submodule update --init
CHIMERA=<path to a Chimera checkout>
git -C "$CHIMERA" submodule update --init extern/chimera-common-minibox
MB="$CHIMERA/extern/chimera-common-minibox"
meson setup "$MB/build/meson-cpp" "$MB" -Dguest_cpp=true && meson compile -C "$MB/build/meson-cpp"
```

The miniBox build downloads the GCC source once to build libstdc++.

## Sources

- Gearcoleco 1.7.6 (`extern/gearcoleco`, commit 063fa521), GPL-3.0-or-later.
  Built: the emulator (`src/`, `src/audio/`) and miniz, the list of
  Gearcoleco's libretro core without its libretro frontend. Defines:
  `GEARCOLECO_DISABLE_DISASSEMBLER`, `GEARCOLECO_FIXED_RANDOM_SEED`,
  `MINIZ_NO_TIME`.
- `patches/0001-chimera-hooks.patch`, applied at every meson configure by
  `waterbox/apply-patches.sh`.

## Building

```
meson setup build/meson-native -Dminibox_dir="$MB" && ninja -C build/meson-native   # run-native, run-wbx
sh waterbox/setup-guest.sh -m "$MB" && ninja -C build/meson-guest core.wbx           # the guest
./waterbox/build-package.sh -m "$MB" -r "$CHIMERA"
```

The package lands at `$CHIMERA/build/Cores/gearcoleco.chimeraCore`. A
package built by hand is stamped `<commit>+local` (`-dirty` with changes,
and the applied patch counts as one); CI sets `CORE_VERSION`.

## The tests

Rebuild both flavors first: the scripts build nothing.

- `./waterbox/run-gate.sh` - native against sandbox, rerecord, turbo and the
  rest (docs/PLAN.md, "The tests"). Ends `34 ok, 0 failed`; with
  `CHIMERA_ROOT=$CHIMERA` (a built Chimera with this package installed) it
  also runs the engine check, `35 ok`.
- `./waterbox/tests/run-frontend.sh --chimera-root "$CHIMERA"` - Chimera's
  window, headless, with `QT_QPA_PLATFORM=offscreen` or a private X display.
  Ends `6 ok, 0 failed`. Its work folder is `waterbox/tests/work`.
- Chimera's contract tests, on a folder holding only this package:
  `$CHIMERA/build/meson-linux/source/ui/test-packages <folder>`.

The test programs are built from `tests/make-test-content.py` by the scripts
themselves. Games and the real firmware for local runs go in
`tests/roms-local/` (ignored by git): `./waterbox/tests/run-local.sh` runs the
games docs/PLAN.md names with the real BIOS (`Coleco_Bios.bin`), checked by
SHA-1, and with the real ADAM ROMs (`eos.rom`, `writer.rom`, by the SHA-1s
the package pins) also SmartWriter and the games on the ADAM. It says SKIP
for each file that is absent.

## CI

`.github/workflows/chimera.yml`: for x86_64 (ubuntu-24.04) and aarch64
(ubuntu-24.04-arm), the core test script; then Chimera built from main, the
package, the frontend test script, the contract tests and the core test
script again with the engine check; the package is uploaded as
`gearcoleco-<sha>-<arch>`. The daily schedule and a manual run publish a
nightly through Chimera's publish-core workflow. The miniBox cache key
carries `meson --version`.

## Troubleshooting

- "extern/gearcoleco is not checked out": `git submodule update --init`.
- A stale guest after changing compiler flags: delete `build/meson-guest`.
- `apply-patches.sh` decides by a marker; after editing a patch, reset the
  submodule's working tree (`git -C extern/gearcoleco checkout .`).
