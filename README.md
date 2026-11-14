# chimera-core-gearcoleco

[Gearcoleco](https://github.com/drhelius/Gearcoleco) by Ignacio Sanchez as a
core for [Chimera](https://github.com/ToolAssisted-run/chimera), the
tool-assisted speedrun frontend: the **ColecoVision** (with the Super Game
Module, MegaCart, Activision and OCM cartridges, the F18A video chip and the
Super Action, wheel and roller controllers) and the **Coleco ADAM** (its
keyboard, two disk drives, two data pack drives and its cartridge slot).

The package, `gearcoleco.chimeraCore`, goes in Chimera's Cores folder. The
setting Machine picks the ColecoVision or the ADAM.

## What you bring

- The ColecoVision BIOS, OS-7 (8 KB, usually `colecovision.rom` or
  `coleco.rom`; SHA-1 45BEDC4CBDEAC66C7DF59E9E599195C778D86A92). Both
  machines need it.
- For the ADAM: the EOS ROM (8 KB, `eos.rom`) and the SmartWriter ROM (32 KB,
  `writer.rom` or `wp.rom`).
- Your games: cartridges (.col, .cv, .rom, .bin, .zip), ADAM disks (.dsk)
  and data packs (.ddp).

Nothing of Coleco's is in this repository or the package.

## More

- [docs/BUILDING.md](docs/BUILDING.md): building, the tests, CI.
- [docs/PLAN.md](docs/PLAN.md): the design decisions and what was tested.
- [AGENTS.md](AGENTS.md): the short operating guide.
- [LICENSE](LICENSE): MIT for this repository's own files; the package is
  GPL-3.0-or-later, as Gearcoleco is.
