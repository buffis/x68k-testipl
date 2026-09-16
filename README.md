# Sharp X68000 TEST-IPL ROM

A standalone power-on self test for the X68000 family. It tests memory and the
memory-mapped devices, reports on screen and over RS-232C, and stops.

It builds two ways:

- **standalone** — boots nothing. You swap it into the IPL sockets to test a
  machine, but it will not work for running anything else than this test. The
  output contains no Sharp code and needs no ROM dumps to build.
- **injected** (`--ipl FILE`) — rides along in the unprogrammed space of an
  existing IPL and hands the machine over to it once the tests are done, so the
  machine boots as normal. Any 128 KB IPL image works: stock from Sharp, exbios,
  anything else.

An injected build holds the report on screen briefly — 3 s, or 10 s if anything
failed — and then hands over, so the machine boots unattended. A standalone
build has nothing to hand over to, so it stops with the report up.

**No Sharp ROM content is redistributed here.** The source, the build and the
prebuilt images in `bin/` are entirely original; `build.py` needs no ROM dumps.
If you want an *injected* build, or want to run the MAME test harness, you
supply your own dumps — see [Running the tests](#running-the-tests).


## Example run:

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

That is an ACE/PRO/EXPERT, which is why `SCSI MB89352` reads SKIP — those
machines have SASI at `$E96000` and nothing at `$E96020`. A SUPER, XVI,
Compact or X68030 reports OK there.

Every line is mirrored to the RS-232C port.

The two checksum lines print their value in brackets as well as a verdict. The
ROM checksum is the image's own, so it should match what `build.py` printed when
you built it. CGROM is judged against `13C64BFE`, the value every dump in
circulation carries and the one a real X68000 PRO reads. A machine reporting
something else is worth recording rather than assuming faulty — but it is no
longer silently waved through.

## Build

Needs Python 3 and [vasm](http://sun.hasenbraten.de/vasm/) built for
m68k/Motorola syntax. `get-vasm.sh` fetches and builds it for you:

```bash
./get-vasm.sh        # downloads vasm, builds it, installs to tools/
python3 build.py     # build standalone      -> build/

# To chain another IPL instead:
python3 build.py --ipl path/to/ipl.rom --out build-injected
```

Prebuilt standalone images are in `bin/` if you only want to burn a ROM:
`testipl_even.bin` (IC12, D15-D8) and `testipl_odd.bin` (IC11, D7-D0), plus
the combined `testipl.dat` for MAME.

`--ipl` takes any 128 KB IPL image. It finds the largest unprogrammed run in
that image, assembles TEST-IPL to sit there, repoints the reset vector at it and
records the IPL's own entry point to chain to — nothing is hand-maintained per
image, and it refuses to inject over anything that is not fill. `--base ADDR`
overrides the placement if you need it.

Given an image split into even/odd halves, interleave them first — even is
D15-D8, odd is D7-D0:

```python
rom = bytearray(len(even) * 2)
rom[0::2], rom[1::2] = even, odd
```

Outputs:

| file | use |
|---|---|
| `testipl.dat` | the 128 KB ROM image |
| `testipl_even.bin` | D15-D8, the **even** device |
| `testipl_odd.bin` | D7-D0, the **odd** device |

Write to two 27C512-class EPROMs, 64 KB each.

## Which machines it runs on

**One image serves every model.** There is no per-machine build. If you want to
chain into specific per-machine IPLs, that will of course differ though once the
tests are done.

`docs/TESTS.md` goes through every line of the report in detail: what is read or
written at which address, what a pass proves, and what it does not.

`test/tryall.sh` runs all tests from the one image, and `test/tryinject.sh`
covers the injected builds: that the payload lands in unprogrammed space, that
the tests run, that the machine reaches the IPL unattended, and that it boots
to a screen identical to the same IPL with nothing injected.

### Failures name an address

A `FAIL` from any of the memory tests is followed by an indented line saying
where and how, because "some RAM is bad" is not actionable and a bit number is:

```
 Main RAM..................... FAIL
   $00080000 exp $5A52A5A5 got $5B52A5A5
```

or, when the fault is the chip on a megabyte boundary that made sizing stop
early, the mask of every bit that misbehaved:

```
 Main RAM size................ FAIL
   $00100000 stuck bits $00400040
```

The differing bits map straight onto the devices in that bank.

Anything that is visible on screen is, in effect, also testing the CRTC, video
controller, text VRAM, CGROM and the monitor contrast register, since none of
the text would appear without all of them working.

## Running it manually in MAME

> **You need your own Sharp ROM dumps for this.** See
> [Running the tests](#running-the-tests) — they are not included here.

`test/run-mame.sh` stages a rompath with the TEST-IPL image swapped in and
launches MAME on it, so there is nothing to set up first:

```bash
cd test
./run-mame.sh            # watch the standalone build in a window
./run-mame.sh exbios     # watch an injected build boot through to the IPL
./run-mame.sh screen     # print the result screen as text, no window
./run-mame.sh serial     # print the bytes sent to the RS-232C port
RAM=12m ./run-mame.sh    # a different memory fit (lowercase: -ram 12m)
```

TEST-IPL halts with the results on screen, so there is no rush to read them. To
watch the tests go by rather than see only the end state, pass MAME's `-speed`
through by running it directly against the rompath the script staged:

```bash
mame x68kxvi -rompath ./roms -bios ipl12 -window -skip_gameinfo -speed 0.25
```

That form is also how you pick a different model. One image serves all of them —
only the filename MAME expects and the `-bios` differ, which is what `tryall.sh`
automates:

| model | machine and BIOS |
|---|---|
| Compact | `mame x68kxvi -bios ipl12` |
| SUPER / XVI | `mame x68kxvi -bios ipl11` |
| ACE / PRO / EXPERT | `mame x68000 -bios ipl10` |
| X68030 | `mame x68030 -bios ipl13` |

Add `-ram 1m` / `2m` / `4m` / `12m` to test a different memory fit.

**The very first run in a given directory reports `SRAM signature FAIL`.**

MAME starts with blank NVRAM, which is genuinely a machine whose SRAM has
never been written — the same thing a flat backup battery looks like. This
ROM never writes SRAM, so it stays that way: the test harness boots the stock
ROM once first to initialise it, which is what a machine that has been used
looks like.

MAME will also print `WRONG CHECKSUMS` for the IPL on every run. That is
expected: it is our image under Sharp's filename, and MAME runs it anyway.

## Running the tests

The MAME harness needs **Sharp ROM dumps, which are not included here** — they
are copyrighted and none of this repository contains any. Supply your own.

Put a set in a directory named `x68kxvi`, two levels above `test/` (i.e. a
sibling of this repository's parent), or override it with `STOCK=...` where the
scripts allow. The scripts expect these filenames:

| file | what it is |
|---|---|
| `cgrom.dat` | CGROM font mask ROM, 768 KB |
| `iplrom.dat` | IPL 1.0 — ACE / PRO / EXPERT |
| `iplromxv.dat` | IPL 1.1 — SUPER / XVI |
| `iplromco.dat` | IPL 1.2 — Compact |
| `iplrom30.dat` | IPL 1.3 — X68030 |
| `scsiinco.bin`, `scsiexrom.bin` | SCSI ROMs |
| `*.ic11`, `*.ic12` | split ROM halves, if your set has them |

`tryinject.sh` additionally injects into a real IPL image, so it needs at least
one 128 KB IPL to inject into. Everything in `build.py` and the standalone build
works without any of this.

```bash
cd test
./run-mame.sh window     # watch it
./run-mame.sh screen     # print the result screen as text
./run-mame.sh serial     # print the bytes sent to the RS-232C port
./run-mame.sh fault      # inject a stuck RAM bit and show the result
RAM=2m ./run-mame.sh screen

./regress.sh             # the whole suite below, about a minute
./tryall.sh              # the same image on all four emulated models
./tryinject.sh           # the injected builds (needs an IPL image)
```

`regress.sh` is the full check, and all of it passes on MAME 0.289.

## RS-232C output

9600 8N1 on SCC channel A (`$E98005` control, `$E98007` data), which is the
RS-232C port. The SCC baud generator runs from the 5 MHz PCLK, giving a time
constant of 14 and an actual rate of 9765 baud — 1.7% fast, comfortably inside
tolerance. `SCC_TC` in the source is the one constant to change for a different rate.

## Status on real hardware

This has been burned to EPROM and run on a real X68000 PRO. Screen output, the
full test sequence and RS-232C output are all confirmed working on that machine.

