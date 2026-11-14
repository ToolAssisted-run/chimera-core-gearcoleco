#!/usr/bin/env python3
"""Builds the free programs and firmware this repository's tests run.

Usage: make-test-content.py <out dir>

Everything here is our own work, written for this repository's tests, and
is under the repository's licence (LICENSE). Nothing is copied from Coleco's
ROMs: the ColecoVision BIOS and the ADAM's EOS and SmartWriter ROMs are
replaced by small programs that do only what the tests need.

Writes:
  free-os7.rom   8 KiB. Stands in for the ColecoVision BIOS (OS-7). At reset
                 it starts the cartridge at the address in its header ($800A),
                 and it sends each interrupt to the cartridge's header the way
                 OS-7 does (RST 08h-38h to $800C-$801E, the video chip's NMI
                 to $8021). It has none of OS-7's routines or its title
                 screen.
  cv-test.col    32 KiB ColecoVision cartridge (header $55 $AA: no title
                 screen). Each frame (the video chip's NMI counts it) it reads
                 both controllers in joystick and keypad mode, except on
                 every fourth frame, so a quarter of the frames are lag
                 frames. It keeps what it read in RAM ($7000-$7003, 1 for
                 held), counts frames ($7004) and the turns of its waiting
                 loop ($7006, 16 bits: a PAL frame is longer), shows the bytes as tiles on the
                 screen, sets the backdrop colour from player 1's joystick
                 byte and plays a tone on the SN76489 whose pitch the keypad
                 and joystick give.
  cv-sgm.col     The same program, which first turns on the Super Game
                 Module's RAM ($53 = 1: $2000-$7FFF become its 24 KiB), plays
                 a second tone on the module's AY-3-8910 and writes a byte a
                 frame into the module's RAM at $2000 + the frame count.
  adam-writer.rom 32 KiB. Stands in for the ADAM's SmartWriter ROM, which an
                 ADAM runs at $0000 when it starts as a computer. It is the
                 same kind of program (video, controllers, tone), and it also
                 talks to the ADAM's devices through ADAMnet's device control
                 blocks in RAM ($FEC0 on): it reads the keyboard (each key it
                 gets is kept at $8100 + n, the count at $8008), and it reads
                 1 KiB blocks from disk drive 1 and data pack drive 1 in turn
                 (blocks 0-7, over and over). While player 1 holds the left
                 button it writes every fourth one back with one byte
                 changed, so the media change while the program runs.
  adam-eos.rom   8 KiB of $FF with a name in it. Stands in for the EOS ROM,
                 which the test program never calls.
  adam-test.dsk  160 KiB disk image (160 blocks of 1 KiB, block k filled with
                 (k * 7 + i) & $FF).
  adam-test.ddp  256 KiB data pack image, filled the same way.
"""
import os
import sys


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.out = bytearray()
        self.labels = {}
        self.fix = []

    def pc(self):
        return self.origin + len(self.out)

    def org(self, addr, fill=0):
        assert addr >= self.pc(), hex(addr)
        self.out += bytes([fill]) * (addr - self.pc())

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = self.pc()

    def b(self, *data):
        for d in data:
            if isinstance(d, (bytes, bytearray)):
                self.out += d
            else:
                self.out.append(d & 0xFF)

    def w(self, value):
        self.b(value & 0xFF, value >> 8)

    def rel(self, op, name):
        self.b(op, 0)
        self.fix.append(("rel", len(self.out) - 1, name))

    def abs(self, op, name):
        self.b(op, 0, 0)
        self.fix.append(("abs", len(self.out) - 2, name))

    def ld_hl_label(self, name):
        self.abs(0x21, name)

    def word_label(self, name):
        self.b(0, 0)
        self.fix.append(("abs", len(self.out) - 2, name))

    def resolve(self):
        for kind, at, name in self.fix:
            if kind == "rel":
                rel = self.labels[name] - (self.origin + at + 1)
                assert -128 <= rel < 128, name
                self.out[at] = rel & 0xFF
            else:
                self.out[at:at + 2] = self.labels[name].to_bytes(2, "little")
        return self.out


# ---- pieces both programs share -------------------------------------------

VDP_DATA, VDP_CTL = 0xBE, 0xBF


def vdp_reg(a, reg, value):
    a.b(0x3E, value, 0xD3, VDP_CTL, 0x3E, 0x80 | reg, 0xD3, VDP_CTL)


def vdp_addr(a, addr):
    """Set the video chip's address for writing (LD A,n; OUT x2)."""
    a.b(0x3E, addr & 0xFF, 0xD3, VDP_CTL, 0x3E, 0x40 | (addr >> 8), 0xD3, VDP_CTL)


def patterns():
    """16 tiles, one for each hex digit, each a different pattern of bits,
    and tile 16, blank, for the rest of the screen."""
    out = bytearray()
    for k in range(16):
        for r in range(8):
            out.append(((k * 0x11) ^ (r * 0x24) ^ (0x80 >> (k & 7))) & 0xFF)
    return out + bytes(8)


def video_setup(a):
    """Graphics mode 1, display off while the tables are written."""
    for reg, value in ((0, 0x00), (1, 0x80), (2, 0x06), (3, 0x80), (4, 0x00),
                       (5, 0x36), (6, 0x07), (7, 0x01)):
        vdp_reg(a, reg, value)
    # the 17 tiles at $0000
    vdp_addr(a, 0x0000)
    a.ld_hl_label("tiles")
    a.b(0x06, 136, 0x0E, VDP_DATA, 0xED, 0xB3)      # LD B,136; LD C,$BE; OTIR
    # the colour table at $2000: white on dark blue
    vdp_addr(a, 0x2000)
    a.b(0x06, 32, 0x3E, 0xF4)                       # LD B,32; LD A,$F4
    a.label("colours")
    a.b(0xD3, VDP_DATA)
    a.rel(0x10, "colours")                          # DJNZ
    # the name table at $1800 and the sprite table after it: tile 16
    vdp_addr(a, 0x1800)
    a.b(0x01, 0x00, 0x04)                           # LD BC,$0400
    a.label("names")
    a.b(0x3E, 16, 0xD3, VDP_DATA, 0x0B, 0x78, 0xB1) # LD A,16; OUT; DEC BC; LD A,B; OR C
    a.rel(0x20, "names")                            # JR NZ
    # no sprites: $D0 ends the sprite list at $1B00
    vdp_addr(a, 0x1B00)
    a.b(0x3E, 0xD0, 0xD3, VDP_DATA)
    # display on, the frame interrupt (NMI) on, 16 KiB
    vdp_reg(a, 1, 0xE0)
    # SN76489: tone 0 at full volume, the others off
    for v in (0x90, 0xBF, 0xDF, 0xFF):
        a.b(0x3E, v, 0xD3, 0xFF)


def nmi_handler(a, frames):
    """Acknowledge the video chip, count the frame."""
    a.b(0xF5)                                       # PUSH AF
    a.b(0xDB, VDP_CTL)                              # IN A,($BF)
    a.b(0x3A); a.w(frames)                          # LD A,(frames)
    a.b(0x3C)                                       # INC A
    a.b(0x32); a.w(frames)                          # LD (frames),A
    a.b(0xF1, 0xED, 0x45)                           # POP AF; RETN


def wait_frame(a, frames, spin):
    """Wait for the next frame's NMI, counting the turns of the loop in a
    16-bit counter: a longer frame (PAL) counts more."""
    a.b(0x3A); a.w(frames)                          # LD A,(frames)
    a.b(0x47)                                       # LD B,A
    a.label("wait")
    a.b(0x2A); a.w(spin)                            # LD HL,(spin)
    a.b(0x23, 0x22); a.w(spin)                      # INC HL; LD (spin),HL
    a.b(0x3A); a.w(frames)
    a.b(0xB8)                                       # CP B
    a.rel(0x28, "wait")                             # JR Z


def clear_vars(a, base, n):
    a.b(0x21); a.w(base)                            # LD HL,base
    a.b(0x06, n, 0xAF)                              # LD B,n; XOR A
    a.label("clear")
    a.b(0x77, 0x23)                                 # LD (HL),A; INC HL
    a.rel(0x10, "clear")


def read_controllers(a, v, frames):
    """Both controllers in both modes, 1 for held; skipped every 4th frame."""
    a.b(0x3A); a.w(frames)
    a.b(0xE6, 3, 0xFE, 3)                           # AND 3; CP 3
    a.rel(0x28, "noinput")                          # JR Z
    a.b(0xD3, 0xC0)                                 # joystick mode
    for i, port in ((0, 0xFC), (1, 0xFF)):
        a.b(0xDB, port, 0x2F, 0x32); a.w(v + i)     # IN; CPL; LD (v+i),A
    a.b(0xD3, 0x80)                                 # keypad mode
    for i, port in ((2, 0xFC), (3, 0xFF)):
        a.b(0xDB, port, 0x2F, 0x32); a.w(v + i)
    a.label("noinput")


def show_bytes(a, row, addrs):
    """Each byte as two tiles (high digit, low digit) along a row."""
    vdp_addr(a, 0x1800 + row * 32)
    for addr in addrs:
        a.b(0x3A); a.w(addr)                        # LD A,(addr)
        a.b(0x0F, 0x0F, 0x0F, 0x0F, 0xE6, 0x0F)     # RRCA x4; AND $0F
        a.b(0xD3, VDP_DATA)
        a.b(0x3A); a.w(addr)
        a.b(0xE6, 0x0F, 0xD3, VDP_DATA)


def backdrop_and_tone(a, v):
    a.b(0x3A); a.w(v)                               # LD A,(joystick 1)
    a.b(0xE6, 0x0F, 0xD3, VDP_CTL, 0x3E, 0x87, 0xD3, VDP_CTL)
    a.b(0x3A); a.w(v + 2)                           # keypad 1: tone's low bits
    a.b(0xE6, 0x0F, 0xF6, 0x80, 0xD3, 0xFF)
    a.b(0x3A); a.w(v)                               # joystick 1: high bits
    a.b(0xE6, 0x3F, 0xF6, 0x04, 0xD3, 0xFF)


# ---- the BIOS stand-in --------------------------------------------------------

def free_os7():
    a = Asm(0x0000)
    a.b(0xF3, 0x31); a.w(0x7400)                    # DI; LD SP,$7400
    a.b(0x2A); a.w(0x800A)                          # LD HL,($800A)
    a.b(0xE9)                                       # JP (HL)
    for rst, target in ((0x08, 0x800C), (0x10, 0x800F), (0x18, 0x8012), (0x20, 0x8015),
                        (0x28, 0x8018), (0x30, 0x801B), (0x38, 0x801E)):
        a.org(rst, 0xFF)
        a.b(0xC3); a.w(target)
    a.org(0x0066, 0xFF)
    a.b(0xC3); a.w(0x8021)
    a.org(0x0100, 0xFF)
    a.b(*b"chimera-core-gearcoleco free OS-7 stand-in: no Coleco code\x00")
    a.org(0x2000, 0xFF)
    return a.resolve()


# ---- the ColecoVision cartridge ------------------------------------------------

def cv_cart(sgm):
    ram = 0x7000
    v, frames, sum_ = ram, ram + 4, ram + 5
    a = Asm(0x8000)
    a.b(0x55, 0xAA)                                 # no title screen
    a.org(0x800A)
    a.word_label("start")                           # $800A: the start address
    # $800C-$801E: RST 08h-38h; nothing here uses them
    for _ in range(6):
        a.b(0xC9, 0x00, 0x00)                       # RET
    a.b(0xFB, 0xED, 0x4D)                           # $801E (IRQ): EI; RETI
    a.abs(0xC3, "nmi")                              # $8021: the frame NMI
    a.b(*b"CHIMERA TEST/GEARCOLECO/2026")
    a.label("nmi")
    nmi_handler(a, frames)
    a.label("start")
    a.b(0xF3, 0x31); a.w(0x7400)                    # DI; LD SP,$7400
    if sgm:
        a.b(0x3E, 0x01, 0xD3, 0x53)                 # SGM RAM at $2000-$7FFF
    clear_vars(a, ram, 16)
    video_setup(a)
    if sgm:
        # AY-3-8910: tone A on, at full volume
        for reg, value in ((7, 0x3E), (8, 0x0F), (0, 0x40), (1, 0x01)):
            a.b(0x3E, reg, 0xD3, 0x50, 0x3E, value, 0xD3, 0x51)
    a.label("main")
    wait_frame(a, frames, ram + 6)
    read_controllers(a, v, frames)
    show_bytes(a, 0, [v, v + 1, v + 2, v + 3, frames, sum_])
    backdrop_and_tone(a, v)
    # a running sum, so RAM depends on every frame's input
    a.b(0x3A); a.w(v + 1)                           # LD A,(joystick 2)
    a.b(0x47, 0x3A); a.w(v + 3)                     # LD B,A; LD A,(keypad 2)
    a.b(0xA8, 0x47, 0x3A); a.w(sum_)                # XOR B; LD B,A; LD A,(sum)
    a.b(0x80, 0x07, 0x32); a.w(sum_)                # ADD A,B; RLCA; LD (sum),A
    if sgm:
        a.b(0x3A); a.w(v + 1)                       # AY tone A from joystick 2
        a.b(0x47, 0x3E, 0x00, 0xD3, 0x50, 0x78, 0xD3, 0x51)
        a.b(0x3A); a.w(frames)                      # a byte a frame into the
        a.b(0x6F, 0x26, 0x20)                       # module's RAM at $2000+n
        a.b(0x3A); a.w(sum_)
        a.b(0x77)                                   # LD (HL),A
    a.abs(0xC3, "main")
    a.label("tiles")
    a.b(patterns())
    code = a.resolve()
    code += bytes([0xFF]) * (0x8000 - len(code))
    return code


# ---- the ADAM's SmartWriter stand-in -------------------------------------------

PCB = 0xFEC0


def dcb(n):
    return PCB + 4 + 21 * n


def adam_writer():
    ram = 0x8000
    v, frames, sum_ = ram, ram + 4, ram + 5
    keycount, lastkey, kbuf = ram + 8, ram + 9, ram + 10
    disk_vars, ddp_vars = ram + 0x20, ram + 0x30   # +0 ok, +1 errors, +2 block, +3 sum, +4 buffer
    keylog = 0x8100
    a = Asm(0x0000)
    a.b(0xF3, 0x31); a.w(0xFE00)                    # DI; LD SP,$FE00
    a.abs(0xC3, "start")
    a.org(0x0038)
    a.b(0xFB, 0xED, 0x4D)                           # EI; RETI
    a.org(0x0066)
    nmi_handler(a, frames)
    a.org(0x0080)
    a.b(*b"CHIMERA TEST/GEARCOLECO/ADAM/2026")
    a.org(0x0100)
    a.label("start")
    clear_vars(a, ram, 0x40)
    # each drive's buffer
    for vars_, buf in ((disk_vars, 0x9000), (ddp_vars, 0x9400)):
        a.b(0x21); a.w(buf); a.b(0x22); a.w(vars_ + 4)   # LD HL,buf; LD (vars+4),HL
    video_setup(a)
    a.label("main")
    wait_frame(a, frames, ram + 6)
    read_controllers(a, v, frames)
    # the keyboard, through device control block 1 (ADAMnet device 1)
    kb = dcb(1)
    a.b(0x3A); a.w(kb)                              # LD A,(status)
    a.b(0xB7)                                       # OR A
    a.rel(0x28, "kbissue")                          # idle: ask for a key
    a.b(0xFE, 0x80)                                 # CP $80
    a.rel(0x38, "kbdone")                           # 1-4: still working
    a.rel(0x20, "kbissue")                          # an answer but no key
    a.b(0x3A); a.w(kbuf)                            # a key: keep it
    a.b(0x32); a.w(lastkey)
    a.b(0x47, 0x3A); a.w(keycount)                  # LD B,A; LD A,(count)
    a.b(0x6F, 0x26, keylog >> 8, 0x70)              # LD L,A; LD H,$81; LD (HL),B
    a.b(0x3C, 0x32); a.w(keycount)                  # INC A; LD (count),A
    a.label("kbissue")
    a.b(0x21); a.w(kbuf); a.b(0x22); a.w(kb + 1)    # buffer
    a.b(0x21); a.w(1); a.b(0x22); a.w(kb + 3)       # length 1
    a.b(0x3E, 0x04, 0x32); a.w(kb)                  # command: read
    a.label("kbdone")
    # the two drives
    a.b(0xFD, 0x21); a.w(dcb(4))                    # LD IY,disk 1's block
    a.b(0xDD, 0x21); a.w(disk_vars)                 # LD IX,its variables
    a.abs(0xCD, "media")
    a.b(0xFD, 0x21); a.w(dcb(8))                    # data pack 1
    a.b(0xDD, 0x21); a.w(ddp_vars)
    a.abs(0xCD, "media")
    show_bytes(a, 0, [v, v + 1, v + 2, v + 3, frames, sum_])
    show_bytes(a, 1, [keycount, lastkey, disk_vars, disk_vars + 1, disk_vars + 3,
                      ddp_vars, ddp_vars + 1, ddp_vars + 3])
    backdrop_and_tone(a, v)
    a.b(0x3A); a.w(v + 1)
    a.b(0x47, 0x3A); a.w(lastkey)
    a.b(0xA8, 0x47, 0x3A); a.w(sum_)
    a.b(0x80, 0x07, 0x32); a.w(sum_)
    a.abs(0xC3, "main")

    # media: IY = the drive's device control block, IX = its variables
    a.label("media")
    a.b(0xFD, 0x7E, 0)                              # LD A,(IY+0): status
    a.b(0xB7)
    a.rel(0x28, "missue")                           # idle
    a.b(0xFE, 0x80)
    a.b(0xD8)                                       # RET C: still working
    a.rel(0x20, "merror")
    # a block came: count it, add its first two bytes to the sum, go on
    a.b(0xDD, 0x34, 0)                              # INC (IX+0)
    a.b(0xDD, 0x6E, 4, 0xDD, 0x66, 5)               # LD L,(IX+4); LD H,(IX+5)
    a.b(0x7E, 0x23, 0x86, 0xDD, 0x86, 3)            # LD A,(HL); INC HL; ADD A,(HL); ADD A,(IX+3)
    a.b(0xDD, 0x77, 3)                              # LD (IX+3),A
    a.b(0xDD, 0x7E, 2, 0x3C, 0xE6, 0x07)            # next block, 0-7
    a.b(0xDD, 0x77, 2)
    a.rel(0x18, "missue")
    a.label("merror")
    a.b(0xDD, 0x34, 1)                              # INC (IX+1): try again
    a.label("missue")
    a.b(0xDD, 0x7E, 4, 0xFD, 0x77, 1)               # buffer address
    a.b(0xDD, 0x7E, 5, 0xFD, 0x77, 2)
    a.b(0xFD, 0x36, 3, 0x00, 0xFD, 0x36, 4, 0x04)   # length $0400
    a.b(0xDD, 0x7E, 2, 0xFD, 0x77, 5)               # block number
    a.b(0xFD, 0x36, 6, 0, 0xFD, 0x36, 7, 0, 0xFD, 0x36, 8, 0)
    # while player 1 holds the left button, every fourth block that came
    # back is written back, one byte changed (so a run that holds nothing
    # only reads, and shows what an earlier run wrote)
    a.b(0x3A); a.w(v)                               # LD A,(joystick 1)
    a.b(0xE6, 0x40)                                 # AND $40: left button
    a.b(0x3E, 0x04)                                 # LD A,4: read
    a.rel(0x28, "mcommand")
    a.b(0xDD, 0x7E, 0, 0xE6, 3, 0xFE, 3)            # LD A,(IX+0); AND 3; CP 3
    a.b(0x3E, 0x04)                                 # LD A,4: read
    a.rel(0x20, "mcommand")
    a.b(0xDD, 0x6E, 4, 0xDD, 0x66, 5)               # LD L,(IX+4); LD H,(IX+5)
    a.b(0x3A); a.w(frames)
    a.b(0x77)                                       # LD (HL),A
    a.b(0x3E, 0x03)                                 # LD A,3: write
    a.label("mcommand")
    a.b(0xFD, 0x77, 0)                              # LD (IY+0),A
    a.b(0xC9)
    a.label("tiles")
    a.b(patterns())
    code = a.resolve()
    code += bytes([0xFF]) * (0x8000 - len(code))
    return code


def image(blocks):
    out = bytearray()
    for k in range(blocks):
        out += bytes(((k * 7 + i) & 0xFF) for i in range(1024))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    files = {
        "free-os7.rom": free_os7(),
        "cv-test.col": cv_cart(False),
        "cv-sgm.col": cv_cart(True),
        "adam-writer.rom": adam_writer(),
        "adam-eos.rom": (b"chimera-core-gearcoleco free EOS stand-in: no Coleco code\x00"
                         + bytes([0xFF]) * 8192)[:8192],
        "adam-test.dsk": image(160),
        "adam-test.ddp": image(256),
    }
    sizes = {"free-os7.rom": 8192, "cv-test.col": 32768, "cv-sgm.col": 32768,
             "adam-writer.rom": 32768, "adam-eos.rom": 8192,
             "adam-test.dsk": 163840, "adam-test.ddp": 262144}
    for name, data in files.items():
        assert len(data) == sizes[name], (name, len(data))
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)


if __name__ == "__main__":
    main()
