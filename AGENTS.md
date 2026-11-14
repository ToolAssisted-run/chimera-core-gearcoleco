# AGENTS.md - Gearcoleco core for Chimera

This repository builds Gearcoleco (ColecoVision and Coleco ADAM) as a
sandboxed guest for Chimera. It produces one file, `gearcoleco.chimeraCore`.
`docs/BUILDING.md` has the details; `docs/PLAN.md` the reasons.

## Layout

- `extern/gearcoleco/` - upstream, a submodule pinned to tag 1.7.6, never
  edited in place.
- `patches/0001-chimera-hooks.patch` - every change to upstream: a fixed
  seed for power-on memory, and the hook called at each read of the
  controllers or the ADAM keyboard. Applied by `waterbox/apply-patches.sh`
  (meson runs it; it checks for the marker `gearcoleco_input_read_hook`).
- `meson.build` - one description, two flavors: native (`run-native`,
  `run-wbx`) and guest (`core.wbx`).
- `waterbox/cinterface.cpp` - the adapter, compiled unchanged into both.
- `waterbox/gate-harness.h`, `run-native.c`, `run-wbx.c` - the runners.
- `waterbox/waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json`, `languages/*.json` (26 languages) - the package's
  declarations.
- `waterbox/run-gate.sh` - the core test script; `waterbox/tests/run-frontend.sh`
  - the frontend test script.
- `tests/make-test-content.py` - builds the free test programs and the
  firmware stand-ins; the test scripts run it, nothing built is committed.
- `tests/roms-local/` - games and firmware for local runs only (ignored by git).
- `licenses/` - licence texts the package carries that upstream does not.

## Commands, in order

```
MB=<chimera>/extern/chimera-common-minibox     # with build/meson-cpp built
meson setup build/meson-native -Dminibox_dir="$MB" && ninja -C build/meson-native
sh waterbox/setup-guest.sh -m "$MB" && ninja -C build/meson-guest core.wbx
./waterbox/run-gate.sh                                   # 34 ok (35 with CHIMERA_ROOT)
./waterbox/build-package.sh -m "$MB" -r <chimera>
<chimera>/build/meson-linux/source/ui/test-packages <folder with only the package>
./waterbox/tests/run-frontend.sh --chimera-root <chimera>   # 6 ok
```

## Rules

- Upstream changes are numbered patches; the series is all or nothing. After
  changing `patches/`, return the submodule's working tree to its pin.
- Determinism is the product: no host clock, no host randomness, no
  threads. A new check is broken on purpose once and seen to fail.
- Every text a person reads is a key of `waterbox/languages/*.json`, in all
  26 languages in the same commit. Control names stay as they are.
- `waterbox.config`, `file_slots.json` and `default_keybinds.json` were
  written by a script once; edit them by hand now, and keep the wire order
  in `cinterface.cpp` and `gate-harness.h` in step with the button lists.
- Never commit a BIOS, a Coleco ROM or a game. No network code.
- Do not write `version` or `versionDate` into `waterbox.config`.
- Commits: `type(scope): what changed`, a short body with what was tested,
  and the trailers in use. Stage explicit paths. Prose is plain ASCII.
