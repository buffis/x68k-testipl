# Sharp X68000 TEST-IPL ROM

A power-on self test for the X68000 family. It takes the machine at reset,
tests memory and the memory-mapped devices, reports on screen and over RS-232C,
and stops.

Two build modes:

- **standalone** — boots nothing. Swap it into the IPL sockets to test a
  machine. Contains no Sharp code and needs no ROM dumps to build.
- **injected** (`--ipl FILE`) — rides along in the unprogrammed space of an
  existing 128 KB IPL, holds the report on screen (3 s, or 10 s if anything
  failed) and then hands over, so the machine boots as normal. Stock Sharp,
  exbios, anything else.

**No Sharp ROM content is redistributed here.** The source, the build and the
prebuilt images in `bin/` are entirely original. An injected build or the MAME
harness needs your own dumps — see [Running the tests](#running-the-tests).

## Example run

```
 SHARP X68000  TEST-IPL  v0.36

 MFP MC68901.................. OK
 CRTC video timing............ OK
 RTC RP5C15................... OK
 RTC oscillator............... OK
 DMAC HD63450................. OK
 OPM YM2151................... OK
 PPI i8255.................... OK
 FDC uPD72065................. OK
 SCSI MB89352................. SKIP
 ROM checksum................. OK (C13644B2)
 CGROM checksum............... OK (13C64BFE)
 Text VRAM.................... OK
 Graphic VRAM................. OK
 Sprite RAM................... OK
 SRAM signature............... OK
 Main RAM size................ 4096K
 Main RAM..................... OK
 Main RAM vs SRAM............. OK

 ALL TESTS PASSED
 Testing done! You can shut down the computer.
```

That is an ACE/PRO/EXPERT: `SCSI MB89352` reads SKIP because those machines
have SASI at `$E96000` and nothing at `$E96020`. A SUPER, XVI, Compact or
X68030 reports OK. Every line is mirrored to the RS-232C port.

The checksum lines print their value as well as a verdict. The ROM checksum is
the image's own, so it should match what `build.py` printed. CGROM is judged
against `13C64BFE` — what a real PRO reads and what every dump in circulation
carries. A machine reporting something else is worth recording rather than
assuming faulty.

A memory FAIL names an address, because "some RAM is bad" is not actionable and
a bit number is:

```
 Main RAM..................... FAIL
   $00080000 exp $5A52A5A5 got $5B52A5A5
```

or, when the fault is on a megabyte boundary and made sizing stop early, the
mask of every bit that misbehaved:

```
 Main RAM size................ FAIL
   $00100000 stuck bits $00400040
```

The differing bits map onto the devices in that bank.

`docs/TESTS.md` goes through every report line: what is read or written at
which address, what a pass proves and what it does not.

## Build

Needs Python 3 and [vasm](http://sun.hasenbraten.de/vasm/) built for
m68k/Motorola syntax:

```bash
./get-vasm.sh        # fetches vasm, builds it, installs to tools/
python3 build.py     # standalone -> build/

python3 build.py --ipl path/to/ipl.rom --out build-injected
```

`--ipl` takes any 128 KB IPL image. It finds the largest unprogrammed run,
assembles TEST-IPL to sit there, repoints the reset vector and records the
IPL's own entry point to chain to; it refuses to inject over anything that is
not fill. `--base ADDR` overrides the placement.

Given an image split into halves, interleave them first — even is D15-D8, odd
is D7-D0:

```python
rom = bytearray(len(even) * 2)
rom[0::2], rom[1::2] = even, odd
```

Outputs, also committed prebuilt in `bin/`:

| file | use |
|---|---|
| `testipl.dat` | the 128 KB ROM image |
| `testipl_even.bin` | D15-D8, the **even** device (IC12) |
| `testipl_odd.bin` | D7-D0, the **odd** device (IC11) |

Write to two 27C512-class EPROMs, 64 KB each.

**One image serves every model.** There is no per-machine build.

## Running the tests

> **You need your own Sharp ROM dumps for this.** They are copyrighted and none
> of this repository contains any.

Put a set in a directory named `x68kxvi` beside the repository's parent, or
override it with `STOCK=...` where the scripts allow:

| file | what it is |
|---|---|
| `cgrom.dat` | CGROM font mask ROM, 768 KB |
| `iplrom.dat` | IPL 1.0 — ACE / PRO / EXPERT |
| `iplromxv.dat` | IPL 1.1 — SUPER / XVI |
| `iplromco.dat` | IPL 1.2 — Compact |
| `iplrom30.dat` | IPL 1.3 — X68030 |
| `scsiinco.bin`, `scsiexrom.bin` | SCSI ROMs |
| `*.ic11`, `*.ic12` | split ROM halves, if your set has them |

`tryinject.sh` also needs at least one 128 KB IPL to inject into. `build.py`
and the standalone build need none of this.

```bash
cd test
./run-mame.sh            # watch the standalone build in a window
./run-mame.sh exbios     # watch an injected build boot through to the IPL
./run-mame.sh screen     # print the result screen as text
./run-mame.sh serial     # print the bytes sent to the RS-232C port
./run-mame.sh fault      # inject a stuck RAM bit
RAM=2m ./run-mame.sh screen

./regress.sh             # full suite, about a minute
./tryall.sh              # the same image on all four emulated models
./tryinject.sh           # injected builds (needs an IPL image)
```

`regress.sh` passes on MAME 0.289. `run-mame.sh` stages the rompath itself, so
there is nothing to set up first. To watch the tests go by rather than see only
the end state, run MAME against that staged rompath directly:

```bash
mame x68kxvi -rompath ./roms -bios ipl12 -window -skip_gameinfo -speed 0.25
```

That is also how you pick a model — only the filename MAME expects and the
`-bios` differ, which is what `tryall.sh` automates:

| model | machine and BIOS |
|---|---|
| Compact | `mame x68kxvi -bios ipl12` |
| SUPER / XVI | `mame x68kxvi -bios ipl11` |
| ACE / PRO / EXPERT | `mame x68000 -bios ipl10` |
| X68030 | `mame x68030 -bios ipl13` |

Add `-ram 1m` / `2m` / `4m` / `12m` for a different memory fit.

Two things to expect under MAME. The very first run in a given directory
reports `SRAM signature FAIL`: MAME starts with blank NVRAM, which is
indistinguishable from a flat backup battery, and this ROM never writes SRAM.
The harness boots the stock ROM once first to initialise it. MAME also prints
`WRONG CHECKSUMS` for the IPL on every run — that is our image under Sharp's
filename.

## RS-232C output

9600 8N1 on SCC channel A (`$E98005` control, `$E98007` data). The baud
generator runs from the 5 MHz PCLK, giving a time constant of 14 and an actual
9765 baud — 1.7% fast, well inside tolerance. `SCC_TC` in the source is the one
constant to change.

## Status on real hardware

Burned to EPROM and run on a real X68000 PRO: screen output, the full test
sequence and RS-232C output all confirmed working.
