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
- For the ADAM: the EOS ROM (`eos.rom`) and the SmartWriter ROM (32 KB,
  `writer.rom`, `wp.rom` or `wp_r80.rom`; SHA-1
  D4AEC4EFE1431E56FE52D83BAF9118542C525255). EOS is 8 KB (the common dump
  is SHA-1 AD3C20EF444F10AF7AE8EB75C81E500D9B1BBA3D), or the 16 KB file of
  MAME and ColEm, whose first 8 KB are the ROM and the only part used.
  Chimera does not check the EOS file; the core does when the ADAM starts,
  and refuses another size or a 16 KB file that does not start with EOS.
  Movies made with the 16 KB file name a different EOS than movies made
  with the 8 KB one.
- Your games: cartridges (.col, .cv, .rom, .bin, .zip), ADAM disks (.dsk)
  and data packs (.ddp).

Nothing of Coleco's is in this repository or the package.

## More

- [docs/BUILDING.md](docs/BUILDING.md): building, the tests, CI.
- [docs/PLAN.md](docs/PLAN.md): the design decisions and what was tested.
- [AGENTS.md](AGENTS.md): the short operating guide.
- [LICENSE](LICENSE): MIT for this repository's own files; the package is
  GPL-3.0-or-later, as Gearcoleco is.
