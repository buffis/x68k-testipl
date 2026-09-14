# Where a real X68000 PRO differed from MAME

Collected while getting a pre-IPL POST ROM to run on real hardware. Each entry
says what was observed, how, and how confident I am — because some things I
initially blamed on MAME turned out to be bugs in my own code, and those are
listed at the bottom so nobody files them.

MAME version: 0.289 (mame0289-603-g6ae579aed31). Machine: a real X68000 PRO,
IPL 1.0 era, 10 MB, running exbios v1.34.24 with a POST injected ahead of it.

---

## 1. Sprite/PCG RAM is not accessible in every screen mode

**Strongest candidate. Independently corroborated by Sharp's own ROM.**

On the real machine, a **single word read** of `$EB8000` bus-errors when CRTC
R20's low byte is `$16`, and returns data at `$15`, `$11`, `$10`, `$05`, `$01`
and `$00`. `$EB0000` behaves the same way. The controller's *register* space at
`$EB0800` answers in every mode — `$EB0808` accepts a write and reads it back —
so the chip is present and decoding; only its RAM is gated.

R20's low five bits select the dot clock, and `$16` is `/2`, the 768-wide high
resolution mode.

MAME allows access in all modes, so anything touching sprite RAM works under
emulation and bus-errors on hardware.

**Corroboration:** IOCS `_SP_INIT` (call `$C0`, at `$FFC418` in the Compact IPL)
opens with `bsr.w $FFC7A0`, and that routine is purely a guard:

```
FFC7A0:  move.w $E80028,d0     CRTC R20
FFC7A6:  andi.w #$FF,d0
FFC7AA:  cmpi.w #$16,d0
FFC7AE:  bne.b $FFC7B6         not $16 -> proceed
FFC7B0:  moveq #$FF,d0
FFC7B2:  addq.l #4,a7          discard the caller's return address...
FFC7B4:  rts                   ...returning past _SP_INIT entirely
```

Sharp's own code refuses to touch sprite hardware in that mode. That the
hardware bus-errors there, and that IOCS checks for exactly that value, agree.

**Confidence: high.** Directly measured across seven R20 values on hardware,
and the boundary matches the ROM's own test exactly.

**Where:** sprite RAM handlers in `src/mame/sharp/x68k.cpp` / `x68k_v.cpp`.

---

## 2. CRTC registers read back written values; on real silicon they are write-only

`CRTC R00` and `R04` read `$0000` on the real machine while the screen is
plainly being scanned. MAME's `crtc_r` (`src/mame/sharp/x68k_crtc.cpp:468`)
returns `m_reg[offset]` for most registers, so a readback test passes under
emulation and fails on hardware.

MAME already special-cases a few registers (9 returns 0, 10/11 handled
separately), so the structure for per-register read behaviour exists.

**Confidence: high** for R00 and R04, directly observed. I did not test every
register, so the full set of write-only registers is uncharacterised.

---

## 3. `areaset_w` is an unimplemented stub

`src/mame/sharp/x68k.cpp:568` is a `// TODO` that only logs. MAME's own
known-issues comment lists it ("Supervisor area set isn't implemented").

Both the stock IPL and exbios clear it within a few instructions of reset —
`move.b #$00,$E86001`, at `$FF00A8` in IPL 1.0 and `$FF00E6` in exbios — so it
is evidently meant to matter.

**Confidence: the stub is a fact.** Its real behaviour I did *not* characterise:
I suspected it caused a fault of mine and was wrong. Anyone implementing it
would need to establish the semantics independently.

---

## 4. Open-bus reads return clean values instead of floating high

On hardware, undriven bits read as 1. The RP5C15's 4-bit mode register reads
`$F8` on the real machine — low nibble `$8` is the real value, the high nibble
is the undriven half of the bus. MAME returns `$00`.

More generally: a register that does not answer reads `$FF` on hardware and a
defined value under emulation. Any test validated against MAME's clean data is
validated against a fiction.

**Confidence: high** for the RTC observation. This is emulation fidelity in
general rather than one fixable bug, and may not be worth a patch.

---

## 5. Text VRAM appears not to answer before the CRTC is programmed

A probe of off-screen text VRAM (`$E7F000`) that succeeds after `video_init`
fails on a cold machine when run before it. Under MAME text VRAM always
responds.

**Confidence: medium.** Inferred from a probe consistently taking its fallback
path on cold boots and not on warm ones. I did not directly characterise what
reads return in that window, and this is entangled with a bug of my own (see
below), so treat it as a lead rather than a finding.

---

## 6. `$EC0000` is mapped rather than bus-erroring — unverified

A POST diagnostic uses `$EC0000` as a bus-error canary; under MAME it reads
`0000` rather than faulting. **I never confirmed what the real machine does
there**, so this may be correct behaviour. Listed only so nobody assumes it was
checked.

---

## 7. The "keyboard doesn't work properly" note may be stale

`src/mame/sharp/x68k.cpp` lists "Keyboard doesn't work properly (MFP USART)"
under known issues. Driving it from a pre-IPL program, it worked: with MFP timer
B clocking the USART, UCR set for 8N1, the receiver enabled, and the keyboard's
enable command (`%01001xxy`, `$49`) transmitted, a genuine emulated keystroke was
received end to end — which also exercises the 2400 baud timing, since MAME's
rs232 keyboard models real bit timing.

**Confidence: medium.** It worked for this narrow case; the comment may refer to
problems elsewhere.

---

## Not MAME bugs — my own, recorded so they are not filed

These produced symptoms I spent days attributing to hardware or emulation, and
all of them were defects in the POST:

* **"Main RAM stalls after N consecutive writes on a cold boot."** There is no
  such limit. The POST's stack fell back to `$2000` in main RAM when its
  text-VRAM probe failed, and the DRAM pattern test then overwrote its own
  return addresses. A corrupted `rts` and a stalled bus look identical. The
  reported hang addresses (`$1C00` with 2 KB slices, `$400` with 8 KB ones) are
  exactly the slices spanning `$1FFC`.
* **"Sprite RAM is faulty."** Two stacked bugs: an optional test that faulted
  reported FAIL instead of SKIP because the verdict lived in a register the test
  itself clobbered, and the test ran in the wrong screen mode (entry 1 above).
* **The last line of serial output was truncated** (`Handing over to the IP`) on
  the injected build. `serial_char` waits for RR0's tx-buffer-empty before
  writing, which frees the holding register while the previous byte is still in
  the shift register, so the `jmp` to the IPL handed over with up to two bytes
  still on the wire and the IPL's SCC reset cut them off. Fixed by waiting for
  RR1's All Sent bit first.

  **This one is structurally invisible to MAME.** The harness taps *writes* to
  the data port, so the byte stream it rebuilds is complete whether or not the
  bytes ever reach the pin. No test here could have caught it; it took a real
  terminal on the other end of a real cable.
* **AREASET, DRAM warm-up, refresh priming, write rate, burst length, the RAM
  expansion board, reset pulse length, mid-run resets** — all investigated, all
  irrelevant to the actual fault.

The RTC oscillator failure on that machine *is* genuine hardware: the RP5C15
answers and its alarm registers read back, but the clock never advances. A dead
32.768 kHz crystal or battery-leakage corrosion, not an emulation difference.
