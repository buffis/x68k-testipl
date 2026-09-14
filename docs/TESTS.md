# What each POST line actually tests

Every line of the report, in the order it prints, with the reasoning behind it.
The short version lives in the README's table; this is the long one — what is
read or written, at which address, what a pass proves, and just as importantly
what it does **not** prove.

Several tests are shaped by things that only show on real silicon, and a few
earlier versions of them passed under MAME while proving nothing. Where that is
the case it is said explicitly, because the failed version is the more useful
warning. `MAME-DIFFERENCES.md` has the evidence for those; `BOOT-SEQUENCE.md`
has the pre-IPL state each test has to cope with.

The report is in two groups: devices first, then memory. Memory is second on
purpose — main RAM is by far the slowest test and the one most likely to hang a
sick machine, so by the time it runs the whole report above it is already on
screen and readable.

---

## Group 1 — devices

### `MFP MC68901`

`$E88000`, registers at `MFP+1+2n`.

Writes `TBCR = 0` to stop Timer B, which turns Timer B's data register (`TBDR`,
reg 16) into plain scratch storage. Then writes `$A5`, reads it back, writes
`$5A`, reads it back, and clears it.

Two complementary patterns, so a bus line stuck high or low cannot pass. Proves
the MFP is decoded, its register file works, and the data bus to it is intact.
Says nothing about its timers, interrupts or serial side.

### `CRTC video timing`

Reads `$E88001` (MFP GPIP, register 0).

This is the CRTC liveness test, and it deliberately never touches the CRTC. The
CRTC register file is write-only on real silicon — a PRO with a visibly correct
768x512 display returns `$0000` from R00, R04 and R20 alike — so the readback
test that used to live here only ever passed because MAME implements those
registers as readable.

Ask the MFP instead. The CRTC drives V-DISP into GPIP bit 4 and H-SYNC into bit
7. The loop samples the port up to 40,000 times, accumulating an OR and an AND
of every sample; `OR & ~AND` is the set of bits that *changed* during the
window. If either video bit moved, the CRTC is generating timing — externally
visible proof that needs nothing to read back. An undriven bus reads all-ones
constantly, so it cancels out of `OR & ~AND` and correctly reports dead rather
than masquerading as live data, which is exactly how the old readback tests were
fooled.

It exits early once both bits have moved, a little over one frame on a healthy
machine; the counter only bounds the dead case. 40,000 iterations is ~200 ms on
a 10 MHz 68000 and still ~60 ms on a 25 MHz 68030 — the window has to be able to
span a frame, since V-DISP only toggles once per ~18 ms.

GPIP bit 6 is the CRTC raster interrupt and is deliberately **not** in the mask:
it only toggles once a raster line has been programmed, so a healthy machine
that never set one would otherwise fail. For the same reason the verdict needs
only one of the two signals, not both.

### `RTC RP5C15`

`$E8A000`, registers at `RTC+1+2n`. Chip and bus only.

Sets the mode register (reg 13) to bank 1, preserving the alarm- and
timer-enable bits. Bank 1 holds the alarm registers, which are plain storage and
do not depend on the oscillator at all. Writes `$5` to alarm register 2, reads
back the low nibble; writes `$A`, reads back. Restores bank 0 before judging, so
the chip is left the way it was found.

Proves the chip is present, its register file works, and the bus to it is good —
and nothing else.

It replaced a check that the seconds and minutes registers held legal BCD, which
says almost nothing: a clock frozen at a plausible time passes it, and it cannot
tell a chip that is not answering from one holding bad data. That old test only
caught the fault on a real PRO by luck, because the registers there happened to
read `$F`, which is not a legal digit.

### `RTC oscillator`

Same chip, different question: does the clock advance?

Sets the mode register's timer-enable bit first. A clock that is merely switched
off is a different thing from a dead oscillator, and only the second is worth
reporting — MAME comes up with the bit clear, which is why the diagnostic page
used to show the time never moving under emulation.

Reads the seconds registers (tens and units nibbles), waits, reads again, up to
four times at about 1.1 s each. Any change passes; four rounds with no movement
is a FAIL.

The wait counts 60 V-DISP transitions via `wait_frames`, not `delay_seconds`.
`delay_seconds` is a calibrated spin loop tuned for a 10 MHz 68000 and runs
several times faster on an X68030, which made its "one second" far too short to
see the clock move and failed this test on a perfectly good machine. Video
frames are ~55 Hz whatever the CPU is doing, so counting them measures real
time. Every step of `wait_frames` is bounded at 200,000 spins, so a CRTC that is
not scanning cannot hang the POST — it returns "not real time" and the test
falls back to `delay_seconds`, and a machine in that state has already failed
the video timing line above.

**This pair is what found the real fault on the PRO this ROM was written for:**
`RTC RP5C15 OK` with `RTC oscillator FAIL` — the chip and its bus are fine, the
32.768 kHz crystal or the battery corrosion around it is not. Splitting one
RTC line into two is what made that diagnosis possible.

### `DMAC HD63450`

`$E84000`.

Channel 0's memory address register (`$0C(a0)`) written and read back with
`$00A5A55A` then `$005AA5A5`, masked to 24 bits since the MAR is 24-bit wide.
Channel 0 is idle at reset, so the register behaves as storage. Proves the
device is decoded and alive.

The DMAC is also *aborted and idled* much earlier, during init, before anything
reads or writes memory in bulk: the HD63450 comes up with undefined registers,
and a channel that powers up armed will arbitrate for the bus and run transfers
of its own. A CPU stalled mid-write with no bus error looks exactly like a DMA
controller holding the bus.

### `OPM YM2151`

`$E90000`.

Reads the status register at `OPM+3` and checks BUSY (bit 7) is clear. The chip
asserts BUSY only while processing a register write; idle, it must read clear.

Minimal, but it is a real signal from the chip rather than a float — a floating
bus reads `$FF`, which has bit 7 set and therefore fails.

### `PPI i8255`

`$E9A000`.

Writes mode word `$92` to the control register (`PPI+7`): mode 0, port A input,
port B input, port C output. Port C is the joystick-select output port, so
configured as output it reads back the last value written. Writes `$0A`, reads
the low nibble; writes `$05`, reads back. Restores `$0F` — all lines high,
joysticks idle — whether it passed or failed.

Complementary nibbles again, so a stuck line cannot pass.

### `FDC uPD72065`

`$E94000`.

Reads the main status register at `FDC+1`, masks `$D0`, and requires exactly
`$80`: RQM set (ready for a command byte), DIO clear (direction is host to FDC),
not busy. That is the defined idle state of the controller.

Passive by design — no command is issued. A POST between reset and handover
cannot safely drive a seek.

### `SCSI MB89352` — optional

`$E96020`. SKIPs on a PRO.

Reads BDID (`SCSI+1`), the host adapter's own SCSI ID, which the controller
reports as a single one-hot bit. `$00` or `$FF` means nothing is answering and
the controller is simply not fitted, which is reported as SKIP rather than as a
fault: internal SCSI only exists on the SUPER, XVI, Compact and X68030, while
the original machine, ACE, EXPERT and PRO have SASI at `$E96000` and nothing at
all at `$E96020`.

A controller that is present but broken still drives the bus, and the one-hot
check (`d2 = d1 - 1; d2 &= d1` must be zero) catches it as a FAIL.

### `MIDI` — optional

`$EAFA00`. SKIPs on an empty slot.

Sharp's CZ-6BM1 is the board this was written against, but it is not the only
one: third-party cards put the same YM3802 at the same addresses, so the test
works on those too. The line says only `MIDI` because nothing it reads can tell
those boards apart.

`tst.b 1(a0)` first: on a machine with no board this bus-errors, and the fault
handler turns that into SKIP, exactly as SCSI does.

Presence alone is not proof the board works, and a floating bus reads `$FF` on
everything, so the board is then asked to prove itself. Every write to the
YM3802 latches the byte into its write-data register, and register 3
(`MIDI+1+3*2`) reads that latch back. Writes `$5A`, reads register 3, writes
`$A5`, reads register 3 — two different patterns rule out a bus stuck high or
low. Register 0 is the write target because it has no side effects; writing
register 1 would reload the register-group select and can reset the device.

**Caveat.** The latch behaviour is modelled on MAME's YM3802 and is **not**
verified against a real CZ-6BM1. A board that is plainly fitted but reports FAIL
here means the latch, not the board, is what to doubt first.

---

## Group 2 — memory

Every RAM test uses the same address-derived fill: each longword gets
`address XOR $5A5AA5A5`, written over the whole region, then the whole region
read back and compared. An address-derived pattern catches aliasing — two
addresses decoding to the same cell — that a constant pattern would miss, and
the XOR keeps neither all-zeroes nor all-ones landing at a convenient address.
A mismatch is reported as `$00080000 exp $5A52A5A5 got $5B52A5A5`; the bits that
differ name the chip.

### `ROM checksum`

`$FE0000`, 128 KB.

32-bit sum of every longword in the image, skipping the one longword that holds
the expected value (`romsum_ref`), then subtracts the reference. Zero is a pass.

Because the ROM sums *itself*, this verifies the EPROM burn — a dropped bit, a
bad socket, a mis-programmed device. It is explicitly **not a test of the
machine**: the machine's own IPL is out of its socket while this ROM is in it.

### `CGROM checksum` — reported as a value, not judged

`$F00000`, 768 KB. Sums 196,608 longwords (3 x 65536) and prints the result in
hex.

There is no verdict because more than one CGROM revision exists and this ROM
deliberately carries no copy of Sharp's to compare against, so a verdict would
be a guess — it was the likeliest source of a false FAIL on a healthy machine.
The value is stable for a given machine, so record it and compare against
another of the same model.

A real PRO reads `13C64BFE`, which matches the CGROM image MAME's `x68000` set
uses byte for byte — so that dump and that machine carry the same revision. If
your machine reports something else, it is not necessarily a fault; record it.

### `Text VRAM`

`$E00000`-`$E7EFFF`, all four planes. Skips the top 4 KB (`$E7F000` up), which
holds the stack and the work area.

Two things about this line are unusual.

The verdict is computed **at startup**, before anything can be printed — the
display has to be trusted before the report means anything — so this line only
reports what was already decided.

And it runs **after** video init and after the CRTC is confirmed scanning: the
text plane is refreshed by the display, so testing it on a cold machine with the
CRTC idle fails as the cells decay.

### `Graphic VRAM`

`$C00000`, 512 KB of real memory.

The 2 MB graphic VRAM window folds onto 512 KB of actual RAM, and how it folds
is set by CRTC R20 bits 8-11. So the test switches R20 to `$0316` — the mode
that maps the first 512 KB through as plain 16-bit words, no nibble packing —
runs the fill and verify, then puts R20 back to `$0B16` for the display.

### `Sprite RAM` — optional

`$EB8000`-`$EBFFFF`. The same fill and verify, wrapped in two mode changes, and
the line with the most history behind it.

Sprite RAM is not reachable in every screen mode, and `video_init` picks one
where it is not. IOCS says so itself: `_SP_INIT` (call `$C0`, at `$FFC418` in
the Compact IPL) opens with a guard that reads CRTC R20, masks the low byte, and
refuses to touch sprite hardware at all when it reads `$16` — which is exactly
what `video_init` writes (`$0B16`, the 768-wide high-resolution mode). Confirmed
on a real PRO: a single word read of `$EB8000` bus-errors at `$0B16` and returns
data at `$0B15`, `$0B11`, `$0B10`, `$0B05`, `$0B01` and `$0B00`.

So the test switches R20 to `$0B15`, saves video controller R2 and sets it to
text-layer-only, and calls `sprite_init`. That writes `$00FF` to the four sprite
timing registers in the order a stock IPL writes them — tapped from a live boot,
since they read back `$FF` and the state after boot does not tell you what was
programmed — and then `$0000` to the control register at `$EB0808`.

The `$0000` matters. That is what MTEST writes, not the `$0010` the IPL leaves
behind. Writing `$0010` with the timing registers set still failed on a real
PRO, and so did `$0000` without them; MTEST does both and works, on the same
machine. Bit 4 looks like a BG enable, and a controller that is fetching from
its own RAM is not going to let the CPU in. The stock IPL never touches sprite
RAM during boot, so there was no enabling sequence of its own to copy.

The display is garbled while this runs, because the rest of the CRTC timing
still describes the old mode. **R20 is restored at the dispatch site, not inside
the test** — that is the only place that survives a bus error, since a fault
unwinds straight past the test's own cleanup.

It is a `run_test_opt`, so a bus error reads SKIP; RAM that answers and gives
back the wrong pattern still fails on its data.

### `SRAM signature` — read-only

`$ED0000`. Compares the first 8 bytes against Human68k's signature string.

Nothing is written, because SRAM holds the user's settings. A failure here
normally means the backup battery is flat and the contents have been lost, not
that the chip is bad — the stock IPL re-initialises SRAM when it sees the same
thing. Since this ROM never writes SRAM, it will keep saying that until the
machine boots Human68k normally again.

### `Main RAM size` — reports a size, not a verdict

A precondition first: the first kilobyte must work before exception vectors can
be installed, so `$0` and `$3FC` get `$C3C35A5A` written and read back. Failure
there is `dead_low`, verdict 4 — a FAIL, deliberately not a SKIP, since no
memory at all is emphatically not something to pass over.

**Phase 1a, tag each megabyte.** Writes `$D0000000 + n` at each megabyte
boundary `n * $100000`, up to 12 MB (where the address space tops out), stopping
at the first tag that does not read back. A bus error here just means running
off the top and is caught by the handler. One dot per megabyte, so a machine
that stalls says where.

**Phase 1b, read every tag back.** Re-reads all of them from the bottom. This is
the phase that catches **aliasing**: on a part-populated machine, high addresses
can fold back onto low memory, so each megabyte's tag reads back fine when it is
written but an earlier one has since been overwritten. Only a second pass over
all of them finds that.

**Phase 1c, absent or present-but-faulty?** Sizing stops at the first megabyte
whose tag does not read back — but that happens both when there is no memory
there and when there is memory with a stuck bit. Left alone, a failing chip
would quietly be reported as a smaller machine.

So at that boundary it writes all-zeroes and reads back (bits that would not go
low), writes all-ones and reads back inverted (bits that would not go high), ORs
the two, and counts the misbehaving bits:

- **8 or fewer** — a device that is present but faulty. FAIL, with the mask on an
  indented line as `$00100000 stuck bits $00400040`. The bit numbers map straight
  onto the chips in that bank.
- **more than 8** — nothing is there. The normal end of memory.

On success the verdict slot prints the size (`4096K`) instead of OK, which is
the point of the line: the machine's memory is on screen before the slow part
below it starts running.

### `Main RAM`

The pattern pass, from `$400` up to the size found above.

It leaves the vector table (`$0`-`$3FF`) alone, since the handlers installed
there are what make a fault survivable. Everything is filled before anything is
verified, so cross-megabyte aliasing is still caught; the 8 KB slicing exists
only to punctuate the progress display.

On screen: the 128 KB block being worked on, as `W$00600400` while writing and
`V$00600400` while verifying, overwritten in place. 80 slices per 10 MB would run off the end of the line as marks, but a
number always fits, and it names exactly which 128 KB block a stall happened in.
It is written *before* each slice, not after, so the address on screen is the
one being worked on when it stops. The field is wiped before the verdict so the
column lines up.

Two guards:

- If `w_ramsize` is zero, sizing already failed and said why — SKIP, rather than
  a second redundant failure.
- If the stack is still below `$E00000`, the text-VRAM fallback was taken and the
  display probe did not rescue it. Patterning would overwrite the return
  addresses under `a7` and hang, so it says SKIP instead of self-destructing.

**That second guard is the residue of the cold-boot hang.** The stack sitting at
`$2000` while the pattern pass swept through `$1FFC` was the actual root cause —
not any of the nine hardware theories that preceded it.

The slice size is not a hardware workaround, incidentally. It was briefly cut to
512 longwords while chasing what looked like a limit on consecutive writes on a
real PRO; that turned out to be this code overwriting its own stack, so the
small slices bought nothing and cost about twelve seconds at 12 MB. They are
back at 2048.

### `Main RAM vs SRAM` — cross-check

Human68k records the memory size it last configured at `$ED0008`. This compares
it against what was just measured, which catches a whole bank having gone
missing.

It SKIPs unless the SRAM value is plausible — non-zero, no more than 12 MB, and
a whole number of megabytes — so an unconfigured machine is not reported as
broken.

The stock IPL rewrites this value on every boot, so **a mismatch only shows on
the first boot after the fault appears.** Under MAME the address is faked from
the configured RAM size rather than read from NVRAM, so there it compares
against the emulated machine's real size.

---

## What is not tested, and why

**ADPCM MSM6258.** Removed. Its only readable register drives a couple of bits
and leaves the rest open, so on real hardware the read returns bus float: a
healthy PRO gave `$FF` on one boot and `$C0` on the next. The old test called
`$FF` "absent", which made it a coin toss rather than a test. Proving this chip
alive means commanding it and observing a state change, which is more than a
POST can do between reset and handing over.

**CRTC register readback.** Removed, for the reason under `CRTC video timing` —
the register file does not read back on real silicon, and the screen carrying
this report is already better evidence that the CRTC is programmed and scanning
than any register comparison could be.

**Keyboard.** Removed entirely.

And implicitly, anything visible on screen is also testing the CRTC, the video
controller, text VRAM, the CGROM and the monitor contrast register, since none
of the text would appear without all of them working.
