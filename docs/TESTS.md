# What each TEST-IPL line tests

Every line of the report, in the order it prints: what is read or written, at
which address, what a pass proves and what it does **not**.

Devices come first, then memory. Main RAM is the slowest test and the one most
likely to hang a sick machine, so by the time it runs the rest of the report is
already on screen.

---

## Group 1 — devices

### `MFP MC68901`

`$E88000`, registers at `MFP+1+2n`.

Writes `TBCR = 0` to stop Timer B, which turns its data register (`TBDR`, reg
16) into scratch storage, then writes `$A5` and `$5A` in turn and reads each
back. Two complementary patterns, so a bus line stuck either way cannot pass.

Proves the MFP is decoded, its register file works and the data bus to it is
intact. Says nothing about its timers, interrupts or serial side.

### `CRTC video timing`

Reads `$E88001` (MFP GPIP, register 0).

This is the CRTC liveness test, and it deliberately never touches the CRTC. The
CRTC register file is write-only on real silicon — a machine with a visibly
correct 768x512 display returns `$0000` from R00, R04 and R20 alike — so a
readback test of it proves nothing, however well it passes under MAME.

Ask the MFP instead. The CRTC drives V-DISP into GPIP bit 4 and H-SYNC into bit
7. The loop samples the port up to 40,000 times, accumulating an OR and an AND
of every sample; `OR & ~AND` is the set of bits that *changed*. If either video
bit moved, the CRTC is generating timing. An undriven bus reads all-ones
constantly, so it cancels out and correctly reports dead rather than
masquerading as live data.

It exits early once both bits have moved, a little over one frame on a healthy
machine; the counter only bounds the dead case. 40,000 iterations is ~200 ms on
a 10 MHz 68000 and still ~60 ms on a 25 MHz 68030 — the window has to span a
frame, since V-DISP only toggles once per ~18 ms.

GPIP bit 6 is the CRTC raster interrupt and is deliberately **not** in the mask:
it only toggles once a raster line has been programmed, so a healthy machine
that never set one would otherwise fail. For the same reason the verdict needs
only one of the two signals.

### `RTC RP5C15`

`$E8A000`, registers at `RTC+1+2n`. Chip and bus only.

Sets the mode register (reg 13) to bank 1, preserving the alarm- and
timer-enable bits. Bank 1 holds the alarm registers, which are plain storage and
do not depend on the oscillator. Writes `$5` to alarm register 2 and reads back
the low nibble, then `$A`. Restores bank 0 before judging, so the chip is left
as it was found.

Proves the chip is present, its register file works and the bus to it is good —
and nothing else. Deliberately not a BCD sanity check on the time registers: a
clock frozen at a plausible time would sail past that.

### `RTC oscillator`

Same chip, different question: does the clock advance?

Sets the mode register's timer-enable bit first — a clock merely switched off is
a different fault from a dead oscillator, and MAME comes up with the bit clear.

Reads the seconds registers, waits, reads again, up to four times at about 1.1 s
each. Any change passes; four rounds with no movement is a FAIL.

The wait counts 60 V-DISP transitions via `wait_frames`, not `delay_seconds`.
`delay_seconds` is a spin loop calibrated for a 10 MHz 68000 and runs several
times faster on an X68030, making its "one second" too short to see the clock
move. Video frames are ~55 Hz whatever the CPU is doing, so counting them
measures real time. Every step of `wait_frames` is bounded at 200,000 spins, so
a CRTC that is not scanning cannot hang the run — it returns "not real time" and
the test falls back to `delay_seconds`. Such a machine has already failed the
video timing line above.

### `DMAC HD63450`

`$E84000`.

Channel 0's memory address register (`$0C(a0)`) written and read back with
`$00A5A55A` then `$005AA5A5`, masked to 24 bits. Channel 0 is idle at reset, so
the register behaves as storage. Proves the device is decoded and alive.

The DMAC is also *aborted and idled* much earlier, during init, before anything
reads or writes memory in bulk: it comes up with undefined registers, and a
channel that powers up armed will arbitrate for the bus and run transfers of its
own. A CPU stalled mid-write with no bus error looks exactly like that.

### `OPM YM2151`

`$E90000`. Reads the status register at `OPM+3` and checks BUSY (bit 7) is
clear; the chip asserts BUSY only while processing a register write.

Minimal, but a real signal rather than a float — a floating bus reads `$FF`,
which has bit 7 set and therefore fails.

### `PPI i8255`

`$E9A000`.

Writes mode word `$92` to the control register (`PPI+7`): mode 0, port A input,
port B input, port C output. Port C is the joystick-select output port, so
configured as output it reads back the last value written. Writes `$0A` and
`$05` in turn, reading the low nibble each time. Restores `$0F` — all lines
high, joysticks idle — whether it passed or failed.

### `FDC uPD72065`

`$E94000`. Reads the main status register at `FDC+1`, masks `$D0` and requires
exactly `$80`: RQM set, DIO clear, not busy — the defined idle state.

Passive by design. A self test between reset and handover cannot safely drive a
seek.

### `SCSI MB89352` — optional

`$E96020`. SKIPs on a PRO.

Reads BDID (`SCSI+1`), the host adapter's own SCSI ID, which the controller
reports as a single one-hot bit. `$00` or `$FF` means nothing is answering and
the controller is simply not fitted: SKIP, not a fault. Internal SCSI only
exists on the SUPER, XVI, Compact and X68030; the original machine, ACE, EXPERT
and PRO have SASI at `$E96000` and nothing at `$E96020`.

A controller that is present but broken still drives the bus, and the one-hot
check (`d2 = d1 - 1; d2 &= d1` must be zero) catches it as a FAIL.

---

## Group 2 — memory

Every RAM test uses the same address-derived fill: each longword gets
`address XOR $5A5AA5A5`, written over the whole region, then read back and
compared. An address-derived pattern catches aliasing — two addresses decoding
to the same cell — that a constant pattern would miss, and the XOR keeps neither
all-zeroes nor all-ones landing at a convenient address. A mismatch reports as
`$00080000 exp $5A52A5A5 got $5B52A5A5`; the bits that differ name the chip.

### `ROM checksum`

`$FE0000`, 128 KB. 32-bit sum of every longword in the image, skipping the one
longword that holds the expected value (`romsum_ref`), minus the reference. Zero
is a pass.

Because the ROM sums *itself*, this verifies the EPROM burn — a dropped bit, a
bad socket, a mis-programmed device. It is explicitly **not a test of the
machine**: the machine's own IPL is out of its socket while this ROM is in it.

### `CGROM checksum`

`$F00000`, 768 KB. Sums 196,608 longwords and compares against `CGROM_SUM`,
`13C64BFE`. A real PRO reads it, and it matches the CGROM image MAME's sets use
byte for byte (a single `cgrom.dat`, CRC `9f3195f1`, shared by all four emulated
machines). The value is printed in brackets either way, so a mismatch gives you
a number to record rather than a bare FAIL.

### `Text VRAM`

`$E00000`-`$E7EFFF`, all four planes. Skips the top 4 KB (`$E7F000` up), which
holds the stack and work area.

Two things about this line are unusual. The verdict is computed **at startup**,
before anything can be printed — the display has to be trusted before the report
means anything — so this line only reports what was already decided. And it runs
**after** video init and after the CRTC is confirmed scanning: the text plane is
refreshed by the display, so testing it with the CRTC idle fails as the cells
decay.

### `Graphic VRAM`

`$C00000`, 512 KB of real memory.

The 2 MB graphic VRAM window folds onto 512 KB of actual RAM, and how it folds
is set by CRTC R20 bits 8-11. The test switches R20 to `$0316` — the mode that
maps the first 512 KB through as plain 16-bit words, no nibble packing — runs
the fill and verify, then puts R20 back to `$0B16` for the display.

### `Sprite RAM` — optional

`$EB8000`-`$EBFFFF`, the same fill and verify wrapped in two mode changes.

Sprite RAM is not reachable in every screen mode, and `video_init` picks one
where it is not. IOCS says so itself: `_SP_INIT` (call `$C0`, at `$FFC418` in
the Compact IPL) opens with a guard that reads CRTC R20, masks the low byte, and
refuses to touch sprite hardware when it reads `$16` — exactly what `video_init`
writes (`$0B16`, 768-wide high resolution). Confirmed on a real PRO: a word read
of `$EB8000` bus-errors at `$0B16` and returns data at `$0B15`, `$0B11`,
`$0B10`, `$0B05`, `$0B01` and `$0B00`.

So the test switches R20 to `$0B15`, saves video controller R2 and sets it to
text-layer-only, and calls `sprite_init`. That writes `$00FF` to the four sprite
timing registers in the order a stock IPL writes them — tapped from a live boot,
since they read back `$FF` — and then `$0000` to the control register at
`$EB0808`.

The display is garbled while this runs, because the rest of the CRTC timing
still describes the old mode. **R20 is restored at the dispatch site, not inside
the test** — the only place that survives a bus error, since a fault unwinds
past the test's own cleanup.

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
memory at all is not something to pass over.

**Phase 1a, tag each megabyte.** Writes `$D0000000 + n` at each megabyte
boundary `n * $100000`, up to 12 MB (where the address space tops out), stopping
at the first tag that does not read back. A bus error here just means running
off the top and is caught by the handler. One dot per megabyte, so a machine
that stalls says where.

**Phase 1b, read every tag back.** Re-reads all of them from the bottom, which
is what catches **aliasing**: on a part-populated machine high addresses can
fold back onto low memory, so each megabyte's tag reads back fine when written
but an earlier one has since been overwritten. Only a second pass finds that.

**Phase 1c, absent or present-but-faulty?** Sizing stops at the first megabyte
whose tag does not read back — which happens both when there is no memory there
and when there is memory with a stuck bit. Left alone, a failing chip would
quietly be reported as a smaller machine.

So at that boundary it writes all-zeroes and reads back (bits that would not go
low), writes all-ones and reads back inverted (bits that would not go high), ORs
the two and counts the misbehaving bits:

- **8 or fewer** — a device that is present but faulty. FAIL, with the mask on
  an indented line as `$00100000 stuck bits $00400040`. The bit numbers map onto
  the chips in that bank.
- **more than 8** — nothing is there. The normal end of memory.

On success the verdict slot prints the size (`4096K`) instead of OK, which is
the point of the line: the machine's memory is on screen before the slow part
below it starts.

### `Main RAM`

The pattern pass, from `$400` up to the size found above.

It leaves the vector table (`$0`-`$3FF`) alone, since the handlers installed
there are what make a fault survivable. Everything is filled before anything is
verified, so cross-megabyte aliasing is still caught; the 8 KB slicing exists
only to punctuate the progress display.

On screen: the block being worked on, as `W$00600400` while writing and
`V$00600400` while verifying, overwritten in place. Marks would run off the end
of the line at 80 slices per 10 MB, but a number always fits and it names
exactly which block a stall happened in. It is written *before* each slice, so
the address on screen is the one being worked on when it stops. The field is
wiped before the verdict so the column lines up.

Two guards:

- If `w_ramsize` is zero, sizing already failed and said why — SKIP, rather than
  a second redundant failure.
- If the stack is still below `$E00000`, the text-VRAM fallback was taken and
  the display probe did not rescue it. Patterning would overwrite the return
  addresses under `a7` and hang, so it says SKIP instead of self-destructing.

### `Main RAM vs SRAM` — cross-check

Human68k records the memory size it last configured at `$ED0008`. This compares
it against what was just measured, which catches a whole bank having gone
missing.

It SKIPs unless the SRAM value is plausible — non-zero, no more than 12 MB and a
whole number of megabytes — so an unconfigured machine is not reported as
broken.
