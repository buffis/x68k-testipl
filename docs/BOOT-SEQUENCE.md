# X68000 boot-up: what the IPL and IOCS actually initialise

Reference notes for writing code that runs *before* the IPL — which is what
this POST does, and why it kept tripping over state nothing had set up yet.

---

## The ROM window and reset

The IPL ROM occupies `$FE0000-$FFFFFF`, 128 KB, as two byte-wide devices: even
bytes (D15-D8) and odd bytes (D7-D0).

At reset the 68000 takes its stack pointer from `$FF0000` and its PC from
`$FF0004`. Both live in the upper half of the ROM window. A stock IPL 1.0 and
exbios both put `$00FF0010` in the reset PC.

## Phase 1 — the first five instructions

Identical in stock IPL 1.0 and in exbios, byte for byte:

```
FF0010:  move.w #$2700,sr       supervisor, all interrupts masked
FF0014:  lea $2000,a7           stack in low DRAM
FF001A:  reset                  assert /RESET to every peripheral
FF001C:  suba.l a0,a0           a0 = 0
FF001E:  move.l #$FF0540,d0     stock IPL; exbios uses $FF0654
FF0024:  bsr.w $FF0510          stock IPL; exbios uses $FF0624
```

Note the stack goes in main RAM at `$2000` immediately, before anything is
configured. A POST cannot copy that if it intends to *test* main RAM — this
one puts its stack in off-screen text VRAM instead.

## Phase 2 — system registers, within a few instructions of reset

Stock IPL 1.0, at `$FF00A8` onward:

```
FF00A8:  move.b #$00,$E86001    AREASET — supervisor area / low-memory access
FF00B0:  move.b #$04,$E8A01F    RP5C15 register 15 (reset control)
FF00B8:  nop / nop
FF00BC:  move.b #$08,$E8A01B    RP5C15 register 13 (mode) — timer enable
```

exbios does the same AREASET write at `$FF00E6`.

`AREASET` (`$E86001`, a byte on the odd lane) governs supervisor-area
protection over low memory. Both IPLs clear it before touching anything else.
**MAME does not implement this register at all**, so its effect cannot be
studied under emulation.

The RTC writes matter more than they look: the RP5C15's clock only advances
while the mode register's **timer-enable bit (`$08`)** is set, and it comes up
clear. Code that reads the RTC without setting it will see a clock that never
ticks and wrongly conclude the oscillator is dead.

## Phase 3 — low memory and the vector tables

The routine the entry code calls (`$FF0510` stock, `$FF0624` exbios) is a
vector-table filler:

```
FF0624:  move.l #$1000000,d1
FF062A:  move.w #$FF,d2         256 longwords per call
FF062E:  move.l d0,(a0)+
FF0630:  add.l d1,d0            +1 in the top byte each time
FF0632:  dbra d2,$FF062E
```

Each entry is the same handler address with an incrementing **top byte**. The
68000 only decodes 24 bits of an address, so every vector points at one common
handler and the spare byte tells that handler which exception fired.

It is called repeatedly over adjacent ranges, so consecutive runs of at least
512 longword writes occur in low memory. Layout:

| range | contents |
|---|---|
| `$000000-$0003FF` | 68000 exception vectors, 256 longwords |
| `$000400-$0007FF` | **IOCS call vectors**, one longword per call number |

IOCS call *n* dispatches through the longword at `$400 + n*4`. Reading that
table out of a booted machine is by far the quickest way to find any IOCS
routine in ROM.

## Phase 4 — video

Order observed in exbios; the stock IPL is equivalent.

1. `$E82600` (VC R2) ← `$0000` — every layer off first
2. `$E82400` (VC R0) ← `$0003`
3. `$E8002A` (CRTC R21) ← `$0133`, then `$0033`
4. `$E80000` (CRTC R00) ← `$0089`, then R01-R08 timing, R09-R19 cleared
5. `$E80028` (CRTC R20) ← `$0316` — memory/display mode
6. `$E8E000` (system port 0) ← `$0E` — **monitor contrast**
7. `$E82600` (VC R2) ← `$0020` — text layer on

Contrast is zero out of reset and the screen stays blank until it is set. That
alone will make a POST look dead while it is running perfectly.

### CRTC R20 and the dot clock

R20's low five bits pick the dot-clock divider, and bit 4 selects the 69 MHz or
39 MHz base:

| R20 & `$1F` | divider | note |
|---|---|---|
| `$00` | /8 | |
| `$01`, `$05` | /4 | |
| `$10` | /6 | |
| `$11`, `$15` | /3 | |
| `$16` | /2 | 768-wide high resolution |
| `$19` | /1.5 | |

**`$16` is the mode in which sprite hardware is unavailable** — see IOCS below.

## Phase 5 — sprite / BG controller

Both IPLs write exactly five registers, timing first and control last:

```
$EB080C ← $00FF        $EB080A ← $00FF
$EB080E ← $00FF        $EB0810 ← $00FF
$EB0808 ← $0010        BG control
```

**Neither the stock IPL nor exbios ever touches sprite RAM** (`$EB0000`,
`$EB8000`) during a whole boot — not one read or write. There is no IPL-level
sprite RAM initialisation to copy. Anything that reaches sprite RAM does so
because Human68k or an IOCS call set it up later.

## Phase 6 — system port and keyboard

| address | meaning | IPL writes |
|---|---|---|
| `$E8E000` | monitor contrast, low nibble | `$0E` |
| `$E8E002` | monitor control, bit 3 | `$08` |
| `$E8E006` | **keyboard enable**, bit 3 | `$08` |
| `$E8E00C` | SRAM write protect | exbios writes `$31` |

The keyboard itself is **mute until the host tells it to talk**. It sends
nothing at all until it receives `%01001xxy` — `$49` — over the MFP USART. The
USART in turn is clocked by **MFP timer B**, so any code that stops timer B (to
borrow TBDR as a scratch register, say) silently kills keyboard input.

## Phase 7 — DMAC

exbios programs HD63450 channels 2 and 3 from `$FF0ED6` (`$E84084` onward). A
POST that runs before the IPL inherits a DMAC in whatever state power-on left
it, unless the `reset` instruction is relied upon to quiet it.

---

## IOCS

IOCS lives in the IPL ROM and is reachable through `trap #15` with the call
number in `d0`, dispatching via the table at `$000400`.

Sprite-group vectors, read from a booted Compact (IPL 1.2):

| call | name | address |
|---|---|---|
| `$C0` | `_SP_INIT` | `$FFC418` |
| `$C1` | `_SP_ON` | `$FFC496` |
| `$C2` | `_SP_OFF` | `$FFC4AC` |
| `$C3` | `_SP_CGCLR` | `$FFC4BE` |
| `$C4` | `_SP_DEFCG` | `$FFC4E4` |
| `$C6` | `_SP_REGST` | `$FFC564` |
| `$C8` | `_BGSCRLST` | `$FFC5D4` |
| `$C9` | `_BGCTRLST` | `$FFC606` |

### `_SP_INIT` refuses to run in high-resolution mode

`_SP_INIT` opens with `bsr.w $FFC7A0`, and that routine is a **guard, not an
initialiser**:

```
FFC7A0:  move.w $E80028,d0     CRTC R20
FFC7A6:  andi.w #$FF,d0
FFC7AA:  cmpi.w #$16,d0
FFC7AE:  bne.b $FFC7B6         not $16 -> carry on
FFC7B0:  moveq #$FF,d0
FFC7B2:  addq.l #4,a7          discard the caller's return address...
FFC7B4:  rts                   ...so this returns past _SP_INIT entirely
```

If CRTC R20's low byte is `$16`, Sharp's own code declines to touch sprite
hardware. That is not advisory, and it does not show under emulation: on real
silicon a single word read of `$EB8000` bus-errors at R20 `$0B16`, and returns
data at `$0B15`, `$0B11`, `$0B10`, `$0B05`, `$0B01` and `$0B00`.

Past the guard, `_SP_INIT` clears `$EB0000-$EB03FF` (sprite scroll registers),
`$EB0800-$EB0809`, and all of `$EB8000-$EBFFFF` (PCG RAM), then loads the PCG
palette at `$E82220`.
