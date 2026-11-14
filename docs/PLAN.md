# chimera-core-gearcoleco: plan and design log

Gearcoleco (Ignacio Sanchez, https://github.com/drhelius/Gearcoleco) as a
Chimera core: the ColecoVision and the Coleco ADAM, from one emulator, in
miniBox's sandbox. Requested in ToolAssisted-run/chimera#581 (the Gear
family); the owner approved building it on 2026-11-14, with every system the
emulator supports.

## 1. Feasibility (docs/new-core.md, section 1), 2026-11-14

- **A new core?** Yes. No core here runs the ADAM. Mesen (and ares) run the
  ColecoVision; Gearcoleco is a separate, more complete emulator of it (the
  Super Game Module, MegaCart, Activision and OCM boards, the F18A video
  chip, the Super Action, wheel and roller controllers) and the only one
  that runs the ADAM with its keyboard, disks and data packs.
- **Licence.** Upstream is pinned at tag 1.7.6, commit
  063fa52151581b356f466905c74a79f9df8d19d7 (2026-10-30). Its LICENSE is the
  GPL version 3, and its sources say "version 3 of the License, or any later
  version". That allows a modified binary to be passed on, with its source.
  Compiled in with it: Blip_Buffer and Sms_Apu by Shay Green (LGPL-2.1 or
  later), miniz 3.1.2 (public domain) and the F18A's 470-byte GPU program
  (src/F18A_enhancements.cpp), which Gearcoleco took from the F18A's VHDL
  source by Matthew Hagerty, released under the 3-Clause BSD licence; its
  notice travels in the package (licenses/F18A-BSD-3-Clause.txt).
- **Compiled-in ROMs.** None of Coleco's. The large tables in src/ are the
  Z80's opcode tables, the DAA table, a game database of CRCs
  (game_db.h), a 256x192 picture shown when no BIOS is loaded (no_bios.h,
  read as 16-bit pixels: 49152 of them, a picture and not code), and the
  F18A program above. The ColecoVision BIOS (OS-7) and the ADAM's EOS and
  SmartWriter ROMs are loaded from files: here, firmware the user brings.
- **One thread, one clock.** Gearcoleco has no threads. A frame is
  `GearcolecoCore::RunToVBlank`, which runs the Z80 to the video chip's
  vertical blank. The only reads of the host's clock: the seed of the random
  numbers that fill memory at power on (`time(NULL)`; patched to a fixed
  seed, patches/0001) and the time stamp of Gearcoleco's own save state
  files, which this core never writes.
- **The picture.** The machine's own framebuffer: Gearcoleco converts the
  video chip's picture into Chimera's byte order (BGRA8888). No GPU.
- **Recompiler.** None; an interpreter.
- **What the user brings.** The ColecoVision BIOS (both machines) and the
  ADAM's EOS and SmartWriter ROMs (the ADAM). Games, disks and data packs.
- **What CI can run.** Our own programs, built from source in the test run
  by tests/make-test-content.py: a stand-in for the BIOS (it starts the
  cartridge and sends its interrupts where OS-7 does), a ColecoVision test
  cartridge (and the same with the Super Game Module), stand-ins for the
  EOS and SmartWriter ROMs (a program that talks to the keyboard, a disk and
  a data pack through ADAMnet), a disk image and a data pack image.
- **Size.** Small: 2.4 MB core.wbx; memory layout 32/4/4/4/32 MiB.

No blocker.

## 2. Shape

Copied from chimera-core-snes9x (a C++ emulator with its own framebuffer):
one meson.build for the native reference and the guest, a shared harness
(waterbox/gate-harness.h) for run-native and run-wbx, the package script,
the frontend test script and the workflow.

Built: Gearcoleco's libretro source list (platforms/libretro/Makefile.common)
without libretro.cpp, with `GEARCOLECO_DISABLE_DISASSEMBLER` (no debugger:
the disassembler alone keeps a table of 8 million pointers) and
`GEARCOLECO_FIXED_RANDOM_SEED`. Not built: the SDL/ImGui desktop program,
its debugger windows and its MCP server, and nothing with network code.

## 3. Decisions

- **Two machines, one package** (2026-11-14). The setting `machine`
  (`colecovision`, `adam`) picks; the system ids are `CV` and `ADAM`. The
  Super Game Module, the cartridge boards and the F18A are not machines of
  their own: Gearcoleco turns them on from what the game does or from the
  game database, and the settings `mapper` and `videoChip` can force them.
- **How the ADAM starts** follows libretro.cpp's ADAM loader exactly: a
  cartridge alone starts as a game (`GC_ADAM_BOOT_CARTRIDGE`); anything in a
  drive, or nothing at all, starts the ADAM as a computer, which runs
  SmartWriter, which boots the drives. The ADAM's cartridge is its own slot
  (`adamcart`, optional), beside `disk1`, `disk2`, `datapack1`,
  `datapack2`. One image per drive; swapping media while running is not
  offered yet.
- **Input.** The ColecoVision's controls are Mesen's names for the same
  controller (Up, Down, Left, Right, Left Button, Right Button, Key 0-9,
  Key *, Key #) plus the Super Action Controller's Purple and Blue, for two
  players, and Reset. Two axes, P1 Spinner and P2 Spinner, are this frame's
  movement of the Super Action Controller's spinner, the driving wheel or
  the roller controller (Gearcoleco's `Spinner1`/`Spinner2`; 0 does
  nothing, so they need no setting). The ADAM adds Computer Reset and its
  keyboard's 74 keys (`Keyboard A` ... `Keyboard Lock`), each with a header
  for TAStudio. Controllers are levels, set every frame as libretro.cpp
  does; the resets act on the frame they are pressed; a keyboard key is
  sent when it goes down (the ADAM repeats a held key on its own clock).
  What the machine was last told is in guest memory, so a savestate carries
  it.
- **Lag frames.** A patch adds `gearcoleco_input_read_hook`, called when
  the program reads a controller port and when the ADAM's keyboard is read
  through ADAMnet. A frame without a call is a lag frame; the call also runs
  Chimera's input-poll callback (a Lua script's `event.oninputpoll`).
- **Reset** is `ResetROMPreservingRAM` (libretro's reset: a cartridge's
  battery memory survives it); **Computer Reset** is `ResetAdamComputer`.
  Gearcoleco's reset of a ColecoVision is a cold one, so there is no
  separate Power button.
- **Save data.** Out: a cartridge's battery memory (EEPROM/SRAM boards) as
  `battery.sav`, and every ADAM disk or data pack the machine wrote to,
  under the name it was mounted by. In: `battery.sav` through the
  `savedata` slot; a written disk goes back in through its drive's slot.
  The media live in guest memory, so a savestate carries what was written.
- **Picture settings** (`overscan`, `noSpriteLimit`) change the picture
  only; `region`, `mapper`, `videoChip` and `machine` are part of the
  machine.
- **Exports** beyond the required ones: memory domains (Work RAM, SGM RAM
  or the ADAM's Main RAM; VRAM; the cartridge's save RAM when it has one;
  the cartridge ROM; the BIOS), a "System Bus" (the Z80's 64 KiB, read
  through Gearcoleco's debugger read, which changes nothing), the Z80's
  registers, turbo (`SetRenderingEnabled` skips only the conversion of the
  picture), the input-poll callback and save data.
- **Firmware.** `colecovision.rom` (8 KiB) is pinned to the common OS-7
  dump, SHA-1 45BEDC4CBDEAC66C7DF59E9E599195C778D86A92 (CRC32 3aa93ef3; the
  same pin as the Mesen core). `eos.rom` (8 KiB, CRC32 05a37a34 is the
  common dump) and `writer.rom` (32 KiB, CRC32 58d86a2a) are declared by
  size and name only: their SHA-1s were not on hand on 2026-11-14 (the
  owner's firmware had not arrived), and are the owner's to pin.

## 4. The tests

`waterbox/run-gate.sh`, 35 checks (34 without a Chimera checkout, where the
engine check says SKIP). Each machine's run is compared native against
sandbox (picture, sound, sample count, lag frames, every memory domain),
saved and loaded around every frame (rerecord), and drawn half the time
(turbo). Beside those: the input shapes the machine; a quarter of the frames
are lag frames (the test program skips every fourth read); the Super Game
Module's RAM and sound are used; videoChip, region and overscan reach the
machine; Reset and Computer Reset change the run; on the ADAM the keyboard,
the disk and the data pack answer the program, the written media come out
as save data, native == sandbox, and go back in; a cartridge alone starts
in the ADAM; a missing BIOS, a disk of the wrong size and save data for a
cartridge that keeps none are refused; each read of the controllers reaches
Chimera's engine.

`waterbox/tests/run-frontend.sh`, 6 checks, in Chimera's window run headless
through projects: a cartridge, held input, a PAL project and an ADAM
project with a disk and a data pack, each byte for byte the native
reference's memory; and both controllers' default keybinds.

Negative controls, 2026-11-14: a copy with six things broken (the input
hook not set, turbo a no-op, the F18A setting ignored, the ADAM's key
presses dropped, the media left out of the save data, PAL ignored) gave
22 ok, 12 failed, each break caught by the check meant for it.

### What the tests do not prove

- The stand-in BIOS has none of OS-7's routines, and the ADAM stand-ins none
  of EOS or SmartWriter. No commercial game has been run with the real
  firmware: the owner's firmware had not arrived. Carnival (SHA-1
  41e08352...) and Oil's Well (779e43f1...) were run for 1800 frames with
  the stand-in BIOS, native == sandbox == rerecord, but they wait on OS-7
  and never read the controllers (1800 lag frames): not played.
- The F18A is run only with the test cartridge, which uses none of its own
  features.
- MegaCart, Activision and OCM boards and battery save data are not run (no
  free cartridge with them yet); `savedata` import is proven refused for a
  cartridge without one, not accepted for one with one.
- The Windows and aarch64 builds and the macOS hosts are CI's (aarch64 by
  the workflow only; nothing was pushed, so it has not run).

## 5. Log

- 2026-11-14: repository made; Gearcoleco pinned at 1.7.6. Both builds,
  the package, Chimera's contract tests (all pass), run-gate.sh 35 ok and
  run-frontend.sh 6 ok on jaffanator01 (in the chimera-dev container).
