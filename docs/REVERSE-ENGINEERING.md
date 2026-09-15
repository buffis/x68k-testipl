# How the IPLs were reverse engineered

This POST runs *before* the IPL, which means it has to know what the IPL does
and — more often — what it does **not** do. Working that out took two tools,
and the split between them is the useful part: most of the answers came from
**dynamic** analysis under MAME, not from reading disassembly.

The reason is that almost every question that mattered was about *ordering* and
*timing* at reset, not about what a routine computes. "Does the IPL write the
supervisor area register, and does it do so before or after it first touches
main RAM?" is not a question a disassembler answers well. A write tap answers it
in one line of output.

No IDA, Ghidra, or radare2 were used. Nothing interactive.

---

## Static disassembly: capstone

[capstone](https://www.capstone-engine.org/) in 68000 mode, driven by a small
wrapper. The wrapper is reproduced in full below — save it as `mdis.py`. Install
capstone without touching the system Python:

```bash
pip install --target /tmp/pylibs capstone
PYTHONPATH=/tmp/pylibs python3 mdis.py FILE
```

The two settings that matter:

```python
md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_000)
md.skipdata = True
```

`CS_MODE_M68K_000` pins the decoder to a plain 68000, so it will not decode
later-CPU encodings that cannot legitimately appear in this code. `skipdata`
keeps it walking past embedded data rather than stopping at the first byte it
cannot decode — ROM images are full of tables, and a disassembler that halts at
the first one is useless on them.

### Why a wrapper is needed at all

capstone alone is wrong on Human68k code in one specific, pervasive way: **DOS
calls are line-F traps**, encoded as words in the range `$FF00`-`$FFFF`. capstone
either renders them as garbage or refuses them, and they are everywhere in a
`.R` executable.

So the wrapper intercepts any word in that range *before* handing bytes to
capstone, and prints it as a named DOS call from a lookup table. Anything
capstone still cannot decode falls back to `dc.w`. The whole thing is 30 lines:

```python
import sys, capstone
data = open(sys.argv[1],'rb').read()
base = 0
md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_000)
md.skipdata = True

DOS = {0x00:"_EXIT",0x01:"_GETCHAR",0x02:"_PUTCHAR",0x09:"_PRINT",0x0a:"_GETS",
       0x0c:"_KFLUSH",0x1b:"_CONCTRL",0x20:"_SUPER",0x23:"_FPUTS",0x25:"_INTVCS",
       0x31:"_KEEPPR",0x4a:"_SETBLOCK",0x4b:"_EXEC",0x4c:"_EXIT2",0x51:"_CURDRV"}

out=[]
off=0
while off < len(data):
    w = int.from_bytes(data[off:off+2],'big')
    if 0xff00 <= w <= 0xffff:            # Human68k DOS call (line-F)
        name = DOS.get(w & 0xff, f"${w&0xff:02X}")
        out.append(f"{base+off:04X}:  {w:04X}            DOS {name}")
        off += 2
        continue
    chunk = data[off:off+10]
    got = list(md.disasm(chunk, base+off, count=1))
    if not got:
        out.append(f"{base+off:04X}:  {w:04X}            dc.w ${w:04X}")
        off += 2
        continue
    i = got[0]
    raw = " ".join(f"{b:02X}" for b in i.bytes)
    out.append(f"{i.address:04X}:  {raw:<15} {i.mnemonic} {i.op_str}")
    off += i.size
print("\n".join(out))
```

IOCS calls go through `trap #15` with the call number in `d0`, so they need no
special handling — capstone decodes the trap, and the preceding `moveq` names
the call.

**Note for IPL images rather than `.R` files:** set `base` to the load address
(`$FE0000`) so branch targets read as real addresses. The `DOS` table is dead
weight there — an IPL makes no DOS calls — but harmless.

---

## Dynamic analysis: MAME + Lua

This is where the real answers came from. MAME takes `-autoboot_script`, and its
Lua API exposes the CPU's address space with read and write taps:

```lua
local mem = manager.machine.devices[":maincpu"].spaces["program"]
_G.tap = mem:install_write_tap(0x000000, 0x00003f, "vectors",
    function (offset, data, mask)
        -- offset, data, mask; return data unchanged to observe passively
        return data
    end)
```

Two practical gotchas, both of which cost time here:

- **Anchor the tap in `_G`.** A tap or notifier held only in a local is garbage
  collected and silently stops firing — you get no output and no error.
- **Return `data` unchanged** unless you are deliberately injecting a fault. The
  same mechanism is what the fault-injection tests use to fake a stuck bit.

Run one against a stock boot with:

```bash
mame x68000 -rompath ./roms -bios ipl10 -video none -sound none -nothrottle \
     -seconds_to_run 20 -autoboot_script test/vectap.lua -autoboot_delay 0
```

### The instruments

Each script in `test/` answers exactly one question. They are kept rather than
deleted because the answers are only as good as the question, and it is worth
being able to re-ask one.

| script | question it answers |
|---|---|
| `resettrace.lua` | where the 68000 actually fetches its reset vector |
| `vectap.lua` | whether the stock IPL installs its own bus/address error vectors, and when |
| `areaset.lua` | whether the IPL writes `$E86001`, and at what point in the sequence |
| `sysinit.lua` | what the IPL writes to the memory controller and system port, relative to first touching main RAM |
| `exbtrace.lua` | every hardware write exbios makes from reset, in order |
| `exbdeep.lua` | whether exbios ever touches AREASET, sprite RAM or the DMAC |
| `exbram.lua` | exbios's longest run of consecutive main-RAM writes |
| `allregs.lua` | every distinct hardware address exbios writes during a full boot, with first value and PC — a systematic sweep for "is there anything we are missing" |
| `earlyall.lua` | everything exbios writes from reset, anywhere, with ascending runs collapsed into one line |
| `mfptrace.lua` | which MFP registers exbios programs, and when |
| `iocsvec.lua` | IOCS call vectors, read out of `$000400` on a booted machine |
| `sprwrites.lua` | every write the stock IPL makes to the sprite/BG controller (several read back `$FF`, so post-boot state is not enough) |
| `sprregs.lua` | what the stock IPL *leaves* in the sprite controller after boot |
| `sprorder.lua` | what the IPL does, in order, before it first touches sprite RAM |
| `rtcprobe.lua` | whether MAME's RP5C15 actually ticks during a run |

### The technique worth stealing

`iocsvec.lua`. Rather than disassembling the IPL to find a routine, **boot the
machine and read the live vector table.** IOCS keeps one longword per call
number at `$000400`, so call `$C0` (`_SP_INIT`) is simply the longword at
`$000400 + 0xC0*4`, and it hands you the entry address directly.

That is how `_SP_INIT` was located at `$FFC418` in the Compact IPL — and
disassembling from there showed it opens with a guard that reads CRTC R20, masks
the low byte, and refuses to touch sprite hardware at all when it reads `$16`.
`$16` is exactly what our `video_init` writes. That one read explained why sprite
RAM bus-errors on real hardware.

Static and dynamic together: the tap finds the address, the disassembler explains
the code there.

### Finding where a machine is stuck

A frame notifier sampling the CPU state, which distinguishes "hung" from
"finished and idling":

```lua
local st = manager.machine.devices[":maincpu"].state
_G.keep = emu.add_machine_frame_notifier(function ()
  print(string.format("PC $%06X SP $%06X", st["PC"].value, st["SP"].value))
end)
```

A PC frozen at one address with the stack pointer back at its initial value is a
machine that *completed* and is parked, not one that crashed. That distinction
resolved an apparent hang in the RAM test that turned out to be the harness
dumping the screen early.

---

## What each approach is good for

**Static** answers "what does this routine do" and "what are the magic constants".
It found the `_SP_INIT` R20 guard and the structure of MTEST's MARCH passes.

**Dynamic** answers "what happens, in what order, and when" — and, crucially,
"what does the IPL *not* do". Several findings here are absences: the stock IPL
never touches sprite RAM during boot, so there was no enabling sequence of its
own to copy. You cannot see an absence in a disassembly listing without reading
all of it; a tap that never fires shows it immediately.

**Neither tells you about real hardware.** Every finding above is about an
*emulated* machine, and `MAME-DIFFERENCES.md` exists because several of them did
not survive contact with a real PRO — MAME's `areaset_w` is a `// TODO` stub, and
its CRTC registers read back where real silicon returns zero. Traces tell you
what the IPL *intends*; only the machine tells you what happens.
