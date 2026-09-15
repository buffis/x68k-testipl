# Sharp X68000 POST ROM

A standalone power-on self test for the X68000 family. It takes the machine at
reset, tests memory and the memory-mapped devices, reports on screen and over
RS-232C, and stops.

It builds two ways:

- **standalone** — boots nothing. You swap it into the IPL sockets to test a
  machine and put the stock ROMs back afterwards. The output contains no Sharp
  code and needs no ROM dumps to build.
- **injected** (`--ipl FILE`) — rides along in the unprogrammed space of an
  existing IPL and hands the machine over to it once the tests are done, so the
  machine boots as normal. Any 128 KB IPL image works: stock Sharp, exbios,
  anything else.

An injected build holds the report on screen briefly — 3 s, or 10 s if anything
failed — and then hands over, so the machine boots unattended. A standalone
build has nothing to hand over to, so it stops with the report up.

**No Sharp ROM content is redistributed here.** The source, the build and the
prebuilt images in `bin/` are entirely original; `build.py` needs no ROM dumps.
If you want an *injected* build, or want to run the MAME test harness, you
supply your own dumps — see [Running the tests](#running-the-tests).

MIT licensed; see [LICENSE](LICENSE).

```
SHARP X68000  POST  v0.36

MFP MC68901................... OK
CRTC video timing............. OK
RTC RP5C15.................... OK
RTC oscillator................ OK
DMAC HD63450.................. OK
OPM YM2151.................... OK
PPI i8255..................... OK
FDC uPD72065.................. OK
SCSI MB89352.................. SKIP
ROM checksum.................. OK
CGROM checksum................ 13C64BFE
Text VRAM..................... OK
Graphic VRAM.................. OK
Sprite RAM.................... OK
SRAM signature................ OK
Main RAM size................. 4096K
Main RAM...................... OK
Main RAM vs SRAM.............. OK

ALL TESTS PASSED
POST complete -- halted.  Power off to swap ROMs
```

OK is green, FAIL is red, and every line is mirrored to the RS-232C port.

CGROM is reported as a checksum rather than judged: more than one CGROM revision
exists and this ROM carries no copy of Sharp's to compare against, so a verdict
would be a guess. The value is stable for a given machine — record it and
compare against another of the same model.

## Build

Needs Python 3 and [vasm](http://sun.hasenbraten.de/vasm/) built for
m68k/Motorola syntax. `get-vasm.sh` fetches and builds it for you:

```bash
./get-vasm.sh        # downloads vasm, builds it, installs to tools/
python3 build.py
```

`build.py` looks for the assembler at `tools/vasmm68k_mot` and does **not**
search `$PATH`, so nothing has to be installed system-wide. If you already have
vasm built elsewhere (`make CPU=m68k SYNTAX=mot`), point at it with `--vasm`.

```bash
python3 build.py                          # standalone      -> build/
python3 build.py --ipl path/to/ipl.rom --out build-injected
```

Prebuilt standalone images are in `bin/` if you only want to burn a ROM:
`ipl_post_even.bin` (IC12, D15-D8) and `ipl_post_odd.bin` (IC11, D7-D0), plus
the combined `ipl_post.dat` for MAME. They are refreshed on each version bump.

`--ipl` takes any 128 KB IPL image. It finds the largest unprogrammed run in
that image, assembles the POST to sit there, repoints the reset vector at it and
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
| `ipl_post.dat` | the 128 KB ROM image |
| `ipl_post_even.bin` | D15-D8, the **even** device (IC12 on a PRO) |
| `ipl_post_odd.bin` | D7-D0, the **odd** device (IC11 on a PRO) |

Two 27C512-class EPROMs, 64 KB each. The payload is about 3 KB, so ~124 KB of
each image is `$FF` fill.

## Which machines it runs on

**One image serves every model.** There is no per-machine build: the POST owns
the machine from reset and boots nothing, so there is no stock IPL to fit around
and no chain-back target that varies.

Verified under MAME on every X68000 it emulates, at 4 MB:

| machines | outcome |
|---|---|
| X68000, ACE, EXPERT, PRO | ALL TESTS PASSED, SCSI SKIP |
| SUPER, XVI | ALL TESTS PASSED |
| Compact, XVI Compact | ALL TESTS PASSED |
| X68030 | ALL TESTS PASSED |

Two notes:

- **Internal SCSI only exists from the SUPER onwards.** ACE/PRO/EXPERT have SASI
  at `$E96000` and nothing at `$E96020`, so that test reports SKIP there rather
  than FAIL.
- **The X68030** runs a 68EC030 rather than a 68000. The POST is plain 68000
  code, VBR is zero out of reset and the caches are off, and discarding the
  whole exception frame means the 030's larger bus-error frame does not matter.
  MAME wants an `scsiinrom.dat` for that machine which we do not have, so the
  harness supplies a stand-in purely to satisfy the ROM loader — our code never
  calls into it.

`docs/TESTS.md` goes through every line of the report in detail: what is read or
written at which address, what a pass proves, and what it does not. The table
below is the short version.

`docs/MAME-DIFFERENCES.md` collects where the real machine behaved differently
from MAME, with the evidence for each and an explicit list of things that turned
out to be our bugs rather than the emulator's.

`docs/REVERSE-ENGINEERING.md` describes the tools this was worked out with —
capstone for static disassembly, and MAME's Lua read/write taps for the
ordering questions a disassembler cannot answer — with the trace scripts in
`test/` indexed by the question each one answers.

`docs/BOOT-SEQUENCE.md` collects what the IPL and IOCS actually initialise, and
what they do not — written up because this POST runs *before* the IPL and kept
tripping over state nothing had set up yet. It also records the hardware
behaviour that only shows on real silicon.

`test/tryall.sh` runs all four from the one image, and `test/tryinject.sh`
covers the injected builds: that the payload lands in unprogrammed space, that
the POST runs, that the machine reaches the IPL unattended, and that it boots to
a screen identical to the same IPL with no POST in it.

## The one system register it must write

`post_entry` clears the supervisor area register at `$E86001` before touching
anything else, because a stock IPL does the same within a few instructions of
reset. It comes up undefined at power-on and governs what low memory may be
written: leave it alone and, on a real PRO, every write above `$400` hangs the
bus on a cold boot while reads of the same addresses work and the vector table
below `$400` stays writable. A warm reset hides it, because the previous run
left the register clear.

MAME's `areaset_w` is an empty TODO, so no amount of emulator testing can show
this — it only appears on real hardware.

## How it takes over the machine

The reset vector is the entire hand-off. At reset the 68000 fetches its stack
pointer and PC from the first two longwords of the IPL ROM, and `build.py` fills
them in:

```
$FF0000:  $00E7FF00     initial SSP
$FF0004:  $00FF0010     reset PC -> the POST
$FF0010:  POST payload, ~3 KB
```

Everything after that the POST does for itself. It sets up its own stack (with a
text-VRAM-then-low-RAM fallback, since main RAM is under test), installs its
own bus and address error handlers before touching any hardware, and runs its own
`serial_init` and `video_init`. Nothing is inherited and nothing is left to
clean up, because nothing runs afterwards.

The ROM checksum test covers the whole 128 KB image including itself, so it
verifies the EPROM burn. It is not a test of the machine — the machine's own IPL
is out of its socket while this ROM is in it.

## What each test does

The report comes in two groups: the devices first, then memory. Memory is second
deliberately — main RAM is by far the slowest test and the one most likely to
hang a sick machine, so by the time it runs everything above it is already on
screen and readable. Within the memory group the size is reported on its own
line before the pattern test that works over it.

Tests are deliberately conservative — they prefer reading back a value they just
wrote over expecting a magic constant. The table is a summary; `docs/TESTS.md`
has the full reasoning for each line, including which ones lean on behaviour
MAME may idealise.

| test | method |
|---|---|
| Text VRAM | address-derived pattern over `$E00000-$E7EFFF`. Runs **after** video init and after the CRTC is confirmed scanning: the text plane is refreshed by the display, so testing it on a cold machine with the CRTC idle fails as the cells decay |
| CGROM checksum | 32-bit sum of all 768 KB, **reported as a value, not judged** — there is more than one revision and no reference to compare against |
| ROM checksum | 32-bit sum of the whole 128 KB, skipping the longword holding the expected value — the ROM verifies the code you are running, so it checks your EPROM burn |
| Graphic VRAM | pattern over the 512 KB of real graphic VRAM |
| Main RAM size | tags each megabyte and reads every tag back, which catches both the bus error off the top and aliasing on a part-populated machine, then asks whether the megabyte above the top is absent or present-but-faulty. Reports the size it found instead of a verdict, so the machine's memory is on screen before the slow part below it starts. A dot per megabyte sized |
| Main RAM | patterns everything from `$400` up, over the size found above. The 128 KB block being worked on is shown as `W$00600400` while writing and `V$00600400` while verifying, overwritten in place — written before each slice, so a machine that stalls leaves the block it died in on screen. Everything is filled before anything is verified, so cross-megabyte aliasing is still caught; the field is wiped before the verdict so the column lines up |
| Main RAM vs SRAM | compares the measured size against what Human68k recorded at `$ED0008` |
| SRAM signature | read-only check of the Human68k signature; SRAM holds your settings so nothing is written to it |
| MFP | Timer B is stopped, so its data register works as a scratch register: write/read `$A5`/`$5A` |
| CRTC video timing | samples the MFP GPIP and passes if V-DISP (bit 4) or H-SYNC (bit 7) toggled. The CRTC register file is write-only on real silicon, so liveness cannot come from a readback |
| RTC RP5C15 | writes `$5` then `$A` to a bank-1 alarm register and reads each back. Alarm registers are plain storage, so this proves the chip and its bus and says nothing about the clock |
| RTC oscillator | sets the mode register's timer-enable bit, reads the seconds, waits, reads again. A clock that never advances is the classic X68000 failure — dead 32.768 kHz crystal, or battery corrosion around it. Timed by counting V-DISP frames rather than `delay_seconds`, which is calibrated for a 10 MHz 68000 and is several times too fast on an X68030 |
| DMAC | channel 0 memory address register written and read back |
| OPM | status register BUSY bit must be clear when idle |
| FDC | main status register must read RQM set, DIO clear, not busy |
| SCSI | BDID must report the host ID as a single one-hot bit; `$00`/`$FF` means not fitted, which is SKIP rather than FAIL |
| PPI | port C configured as output and read back |
| Sprite RAM | pattern over 32 KB. **Switches CRTC R20 to `$0B15` for the duration**, because sprite RAM is not reachable in the 768-wide mode `video_init` uses. IOCS says so itself: `_SP_INIT` opens with a guard that refuses outright when R20's low byte is `$16`. Confirmed on a real PRO — `$EB8000` bus-errors at `$0B16` and returns data at every lower mode. The display garbles while the test runs and is restored after |

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
Main RAM..................... FAIL
  $00100000 stuck bits $00400040
```

The differing bits map straight onto the devices in that bank.

Anything that is visible on screen is, in effect, also testing the CRTC, video
controller, text VRAM, CGROM and the monitor contrast register, since none of
the text would appear without all of them working.

### The RAM sizing is the subtle one

Sizing works by tagging each megabyte boundary and then reading *every* tag back,
which catches aliasing on a part-populated machine. But sizing alone cannot tell
"there is no memory here" from "there is memory here with a stuck bit" — both
just fail to read back the tag, and a faulty chip would quietly be reported as a
smaller machine.

So at the megabyte where sizing stopped, the POST writes all-zeroes and all-ones
and counts how many bits misbehave. A handful of bad bits means a device that is
present but faulty (FAIL); all 32 means there is nothing there (normal end of
memory). Verified by injecting a stuck bit at `$100000` on a 2 MB machine: without
this it silently reported 1024K and passed, and now it reports FAIL.

Bus and address error handlers are installed at vectors 2 and 3 before anything
touches hardware, so running off the top of memory — or probing a device that is
not fitted on this model — is safe. They cannot resume (a 68000 group 0 fault
never can), so they discard the exception frame and jump to a recovery address.

That recovery address is established per test by `run_test`, which is the whole
reason the dispatcher exists — every probe must have one set, or a bus error
jumps through whatever `a3` happens to hold. Verified by pointing the SCSI test
at unpopulated memory to force a real bus error: the POST reports
SKIP for that line and runs to completion.

A bus error means nothing responded at that address at all, which is why
`run_test_opt` treats it as SKIP for optional hardware — a controller that is
fitted but broken still answers the bus cycle and fails on its data instead.

## Running it manually in MAME

> **You need your own Sharp ROM dumps for this.** See
> [Running the tests](#running-the-tests) — they are not, and cannot be,
> included here.

`test/run-mame.sh` stages a rompath with the POST image swapped in and launches
MAME on it, so there is nothing to set up first:

```bash
cd test
./run-mame.sh            # watch the standalone build in a window
./run-mame.sh exbios     # watch an injected build boot through to the IPL
./run-mame.sh screen     # print the result screen as text, no window
./run-mame.sh serial     # print the bytes sent to the RS-232C port
RAM=12m ./run-mame.sh    # a different memory fit (lowercase: -ram 12m)
```

The POST halts with the results on screen, so there is no rush to read them. To
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

Add `-ram 1m` / `2m` / `4m` / `12m` to test a different memory fit. RAM is a slot
device in current MAME, so it is `-ram 4m`, not the older `-ramsize 4M`.

Three things that will otherwise confuse you:

- **`-skip_gameinfo` is not optional.** Without it MAME stops on its system
  information screen and the machine stays paused, so the POST never starts and
  you get a black window. Pressing a key dismisses it too, but the flag is
  easier to live with.
- **`-bios` is not optional either.** MAME's default for `x68kxvi` is `ipl11`,
  so leaving it off runs the SUPER/XVI image rather than the Compact one.
- **The very first run in a given directory reports `SRAM signature FAIL`.**
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

Two things to know:

- **`-bios ipl12` is mandatory.** MAME's default BIOS for `x68kxvi` is `ipl11`
  (`iplromxv.dat`). The Compact ships IPL 1.2 = `iplromco.dat`, which is the image
  we patch. Without the flag MAME boots a completely different ROM.
- MAME warns that `iplromco.dat` has a wrong checksum. That is expected — it is
  our modified image, and MAME runs anyway.

`regress.sh` is the full check, and all of it passes on MAME 0.289:

- every test passes at 1 MB, 2 MB, 4 MB and 12 MB, with the size reported right
  each time;
- injected faults are actually detected — a flipped bit in the ROM, a simulated
  stuck RAM bit and a frozen MFP GPIP each produce FAIL while every other test
  still reports OK, and a flipped bit in the 768 KB CGROM moves the reported
  CGROM checksum;
- the serial byte stream comes out complete and in order.

Worth saying plainly: an emulator agreeing is not the same as hardware agreeing.
MAME's device models are good but not exhaustive, and a few of these tests lean
on behaviour it may idealise — the MFP timer data register reading back, the PPI
port C readback, and the FDC and SCSI status values in particular. Expect to
adjust one or two once you see what a real Compact reports.

## Timing

Roughly 2.5 s of fixed cost plus 1.25 s per megabyte of RAM, at 10 MHz — so
about 5 s at 2 MB and 7.5 s at 4 MB. An injected build then holds the report for
3 s, or 10 s if anything failed, before handing over to the IPL — without that
pause the whole run would flash past, since the IPL clears the screen on its way
to booting. The serial log has it all either way. If the
RAM pass is too slow for your taste, the pattern test in `test_dram` phase 2 is
the thing to trim.

## RS-232C output

9600 8N1 on SCC channel A (`$E98005` control, `$E98007` data), which is the
RS-232C port; channel B is the mouse. The SCC baud generator runs from the 5 MHz
PCLK, giving a time constant of 14 and an actual rate of 9765 baud — 1.7% fast,
comfortably inside tolerance. `SCC_TC` in the source is the one constant to
change for a different rate.

**The RS-232C port is the one path MAME cannot verify.** Its x68000 driver leaves channel A's
TxD unconnected, so `./run-mame.sh serial` taps the writes to the data port and
rebuilds the byte stream instead — about 1800 bytes on a 4 MB machine, complete
and in order, with nothing dropped. Everything up to the pin is confirmed; the
pin itself needs real hardware and a null-modem cable.

**Confirmed working on a real PRO.** That is also where the one bug MAME
structurally cannot catch turned up: the write tap sees bytes as the CPU hands
them to the SCC, but the injected build jumped to the IPL while the last one or
two were still in the shift register, and the IPL's SCC reset cut them off. The
log ended `Handing over to the IP`. `serial_drain` now waits for RR1's All Sent
bit before the jump. A write tap cannot show that fault or its fix — only a
scope or a real terminal can.

If the SCC never reports its transmitter ready, `serial_init` gives up once and
disables serial for the rest of the run, so a dead or absent SCC costs one
timeout rather than stalling every line of output. That guard is also what caught
the original bug here: the transmitter was being enabled before its clock source
was configured, which latches a rate of zero.

## Design notes worth knowing if you modify this

**There is nowhere obvious to put a stack.** The POST runs at reset with no RAM,
no vector table and no video, and main RAM is one of the things under test, so
it cannot hold the stack.

Graphic VRAM looks like the answer and is a trap: it is 512 KB of real memory
presented through a 2 MB window, and how the window folds onto it depends
entirely on CRTC R20, which is undefined at power-on. In 16-colour mode only four
bits of each word are stored and the window folds four ways. A stack there
silently aliases onto itself.

Text VRAM is flat, but only once CRTC R21 has simultaneous-plane access and the
access mask switched off. So the first thing the POST does is store R20 and R21 —
two stores with no dependencies, safe with no stack — and the stack then lives at
`$E7F000-$E7FEFF`, in plane 3 at text lines 992-1023, which are off the bottom of
a 512-line screen. The work area sits just above it at `$E7FF00`. Both are held
back from the text VRAM test.

**The screen stays black until you set the monitor contrast.** `$E8E001` is the
monitor contrast register, and it is zero coming out of reset — the stock IPL
loads the user's saved value from SRAM at `$FF00D4`, which is long after the POST
runs. Until something writes it, the display is blank no matter how correct the
CRTC, video controller, palette and text VRAM are. `video_init` winds it to
maximum. Nothing restores it afterwards, since nothing runs afterwards — the
next power-on starts from reset again.

This one cost some time, and is worth knowing about because it is invisible to
the obvious test: reading the text plane back proves the *data* is right, not
that anything is *displayed*. It only showed up when checking MAME's rendered
pixels, and it would have been a black screen on real hardware too.

**Video registers are the stock machine's own.** The CRTC and video controller
values are CRTMOD 16 (768x512, 96x32 text), read back from a live boot of the
unmodified ROM rather than derived from documentation. Text palette entries are
overridden to 0 black / 1 white / 2 green / 3 red, so colour comes from which
plane a glyph is written to.

**The header layout is fixed on purpose.** `build.py` patches the ROM checksum
at payload offset +4 without parsing the assembler listing, so `POST_BASE` must
stay longword-aligned — the checksum loop walks longwords and skips the one
holding its own expected value. `build.py` asserts this.

## Status on real hardware

This has been burned to EPROM and run on a real X68000 PRO. Screen output, the
full test sequence and RS-232C output are all confirmed working on that machine.
On the PRO, **SW1** selects between the default internal IPL and the socketed
EPROMs, so flipping one switch puts the machine back to normal and the stock
chips never have to come out.

What that machine found is in `docs/MAME-DIFFERENCES.md`: the CRTC register file
does not read back on real silicon, sprite RAM bus-errors unless the screen mode
allows it, and that PRO's RTC oscillator is dead — the chip answers and its alarm
registers read back, but the clock never advances.

**One caveat about that machine as a reference:** it will not boot its own stock
IPL at all, so anything unusual it reports should be treated as machine-specific
until a second machine agrees. Reports from other X68000s are very welcome —
particularly a Compact, a SUPER/XVI or an X68030, since the device tests have
only been exercised against MAME on those models.

Every model takes the two 64 KB halves directly. The Compact does carry a 1 MB
mask ROM with CGROM + SCSI + IPL together — which is why its `compact.bin` dump
is byteswapped — but it also has IPL slots that take an injected IPL the same
way the other models do, so it needs no special handling.
