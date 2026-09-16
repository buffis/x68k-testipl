#!/usr/bin/env python3
"""
Build the X68000 TEST-IPL ROM.

  standalone (default)
      Pads the payload into a complete 128K image with the reset vector
      pointing at it.  It boots nothing, so the output contains only our code.

  injected (--ipl FILE)
      Puts TEST-IPL into the unprogrammed space of an existing 128K IPL image,
      repoints the reset vector at it, and hands over to that IPL's original
      entry point when the tests are done.  Needs a large unprogrammed run:
      exbios and the X68030 IPL have one, the stock ACE/XVI/Compact IPLs do not.

Either way it fills in the ROM self-check checksum and emits the 128K image
plus the even/odd halves for a pair of 27C512-class EPROMs.

The toolchain is vasm + vbcc + vlink, built by ./get-tools.sh into tools/.

Usage:  python3 build.py [--ipl FILE] [--out DIR] [--cdefine K=V]
"""

import argparse
import pathlib
import re
import struct
import subprocess
import sys

# --- layout ------------------------------------------------------------------
IPL_BASE = 0xFE0000       # the IPL ROM window: $FE0000-$FFFFFF
IPL_LEN = 0x20000         # 128K, two 27C512-class devices
RESET_SSP_ADDR = 0xFF0000  # the 68000 fetches SSP from here at reset
RESET_PC_ADDR = 0xFF0004   # ...and its reset PC from here
TESTIPL_BASE = 0xFF0010    # code starts just past the two reset longwords
STACK_TOP = 0xE7FF00       # initial SSP; TEST-IPL re-derives its own anyway
FILL = 0xFF                # unprogrammed EPROM
ROMSUM_OFF = 4             # checksum field within the payload (see crt0.s)

# Minimum unprogrammed run an injected build will accept.
#
# This is a headroom policy, not a hard limit.  The C payload is ~6.2K, so it
# would physically fit stock ACE (6668 free) with about 400 bytes to spare and
# XVI/Compact (8.1-8.4K) with rather more -- but a single extra test would blow
# it, silently, on whichever machine someone happened not to retest.  exbios
# (65536) and the X68030 IPL (49612) have real room.  Lower this if you want the
# stock IPLs back and are willing to watch the size on every change.
MIN_FREE = 16384

# crt0.s must link first: build.py patches the header blind, so the payload has
# to open with the bra.w and the checksum longword.
ASM_FIRST = ["crt0.s", "runtime.s"]


def u32(b, off):
    return struct.unpack_from(">I", b, off)[0]


def put32(b, off, v):
    struct.pack_into(">I", b, off, v & 0xFFFFFFFF)


def sum32(data, skip=None):
    """Sum of big-endian longwords, mod 2^32.  `skip` is the byte offset of one
    longword to leave out: the field holding the expected value itself."""
    total = 0
    for off in range(0, len(data), 4):
        if skip is not None and off == skip:
            continue
        total += u32(data, off)
    return total & 0xFFFFFFFF


def find_free(ipl):
    """Largest run of a single fill byte ($00 or $FF) in a 128K IPL image, as
    (longword-aligned start address, end address).  The reset vector is
    excluded: on some images the SSP's leading zero bytes end a long blank run
    and would otherwise be handed back as free space."""
    vec = RESET_SSP_ADDR - IPL_BASE
    best = None
    i = 0
    while i < len(ipl):
        b = ipl[i]
        j = i
        while j < len(ipl) and ipl[j] == b:
            j += 1
        if b in (0x00, 0xFF):
            start, end = i, j
            if start < vec + 8 and end > vec:        # clip off the reset vector
                if start < vec:
                    end = min(end, vec)
                else:
                    start = max(start, vec + 8)
            start = (start + 3) & ~3
            if end - start > 0 and (best is None or end - start > best[1] - best[0]):
                best = (start, end)
        i = j
    if best is None:
        sys.exit("no unprogrammed space found in the IPL image")
    return IPL_BASE + best[0], IPL_BASE + best[1]


def run(cmd):
    cmd = [str(c) for c in cmd]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        sys.exit("failed: " + " ".join(cmd))
    if p.stderr.strip():
        sys.stderr.write(p.stderr)
    return p


def preflight(srcdir):
    """No .c file may name a device address or dereference a pointer directly.

    Every MMIO access has to go through the volatile accessors in hw.h, because
    the device tests are write-then-read-back-the-same-address -- exactly what
    an optimiser removes, and a removed read-back passes on dead hardware."""
    bad = []
    for c in sorted(srcdir.glob("*.c")):
        for n, line in enumerate(c.read_text().splitlines(), 1):
            code = line.split("/*")[0].split("//")[0]
            # A cast-and-dereference is the only way to reach hardware without
            # going through hw.h, and the only way to lose the volatile.
            if re.search(r"\*\s*\(\s*(volatile\s+)?"
                         r"(unsigned|signed|u8|u16|u32|char|int|long|short)\b[^)]*\*\s*\)",
                         code):
                bad.append("%s:%d: raw pointer cast -- reach hardware through "
                           "hw.h so the access stays volatile: %s"
                           % (c.name, n, line.strip()))
            # vbcc 0.9i miscompiles a bare volatile lvalue used as a truth
            # value: "if (v)", "if (!v)", "while (v)" and "v ? a : b" drop the
            # read AND the branch, so the body runs unconditionally.  Adding any
            # operator ("v != 0", "v & MASK") makes it emit correct code.  This
            # is silent, so the build refuses the shapes that trigger it.
            if re.search(r"\b(if|while)\s*\(\s*!?\s*(w_[a-z_]+|MMIO\d+\s*\([^()]*\)"
                         r"|[A-Z][A-Z0-9_]*\s*\([^()]*\))\s*\)", code):
                bad.append("%s:%d: bare volatile as a condition -- vbcc drops "
                           "the read; write \"!= 0\": %s" % (c.name, n, line.strip()))
            if re.search(r"\b(w_[a-z_]+|MMIO\d+\s*\([^()]*\))\s*\?", code):
                bad.append("%s:%d: bare volatile in a ternary -- vbcc drops the "
                           "read; write \"!= 0\": %s" % (c.name, n, line.strip()))
    if bad:
        sys.exit("preflight failed:\n  " + "\n  ".join(bad))


def compile_sources(tools, srcdir, out, asm_defines, c_defines):
    """vbcc -> vasm for each .c, vasm for each .s.  Returns object paths with
    crt0.o and runtime.o first, which is what puts the header at offset 0.

    The two define lists are separate because vasm only accepts decimal or $hex
    in -D and warns on the 0x form the C side uses."""
    aflags = ["-D" + d for d in asm_defines]
    cflags = ["-D" + d for d in c_defines]
    objs = []

    for name in ASM_FIRST:
        src = srcdir / name
        obj = out / (src.stem + ".o")
        run([tools / "vasmm68k_mot", "-Fvobj", "-m68000", "-quiet",
             *aflags, "-o", obj, "-L", out / (src.stem + ".lst"), src])
        objs.append(obj)

    for src in sorted(srcdir.glob("*.c")):
        asm = out / (src.stem + ".asm")
        obj = out / (src.stem + ".o")
        run([tools / "vbccm68k", "-cpu=68000", "-sc", "-quiet",
             "-I" + str(srcdir), *cflags, src, "-o=" + str(asm)])
        run([tools / "vasmm68k_mot", "-Fvobj", "-m68000", "-quiet",
             "-o", obj, "-L", out / (src.stem + ".lst"), asm])
        objs.append(obj)

    return objs


def write_linker_script(path, base):
    """Place the header section first at `base`.  .data and .bss are sent to an
    unmapped address on purpose: there is no RAM at reset to initialise them
    from, so anything landing there is a bug, and a bus error is a much louder
    way to find out than a write that silently vanishes into ROM."""
    path.write_text(
        "MEMORY {\n"
        "  rom  : org = 0x%X, len = 0x%X\n"
        "  none : org = 0xFFF00000, len = 0x10000\n"
        "}\n"
        "SECTIONS {\n"
        "  .text : { *(header) *(CODE) *(code) *(text) *(rodata) } > rom\n"
        "  .data : { *(data) *(DATA) } > none\n"
        "  .bss  : { *(bss) *(BSS) } > none\n"
        "}\n" % (base, IPL_LEN))


def check_map(map_text):
    """Fail the build if anything landed outside the code section."""
    sizes = {}
    in_map = False
    for line in map_text.splitlines():
        if line.startswith("Section mapping"):
            in_map = True
            continue
        if in_map:
            if line.startswith("Symbols") or line.startswith("Absolute"):
                break
            m = re.match(r"\s*([0-9a-fA-F]{8})\s+(\S+)\s+\(size ([0-9a-fA-F]+)", line)
            if m:
                sizes[m.group(2)] = int(m.group(3), 16)
    for name, size in sizes.items():
        if name != ".text" and size:
            sys.exit(
                "section '%s' is %d bytes -- there is no RAM at reset, so the "
                "payload must have no .data and no .bss.\nLook for a non-const "
                "global, an uninitialised global, or a static local." % (name, size))
    return sizes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build")
    ap.add_argument("--tools", default="./tools")
    ap.add_argument("--srcdir", default="src")
    ap.add_argument("--cdefine", action="append", default=[], metavar="K=V",
                    help="passed to the compiler and assembler as -DK=V; the "
                         "test harness uses it to move SPRRAM onto an odd "
                         "address and force the optional-test fault path")
    ap.add_argument("--ipl", metavar="FILE",
                    help="inject into this 128K IPL image and chain to it when "
                         "the tests finish, instead of building standalone")
    ap.add_argument("--base", type=lambda v: int(v, 0), metavar="ADDR",
                    help="with --ipl, force the injection address instead of "
                         "using the largest unprogrammed run")
    args = ap.parse_args()

    # The checksum loop skips its own reference longword by address compare,
    # so that field has to be longword aligned.
    assert TESTIPL_BASE % 4 == 0, "TESTIPL_BASE must be longword aligned"
    assert (TESTIPL_BASE + ROMSUM_OFF) % 4 == 0

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tools = pathlib.Path(args.tools)
    srcdir = pathlib.Path(args.srcdir)

    ipl = None
    testipl_base = TESTIPL_BASE
    free_end = IPL_BASE + IPL_LEN
    chain_to = None
    if args.ipl:
        ipl = bytearray(pathlib.Path(args.ipl).read_bytes())
        if len(ipl) != IPL_LEN:
            sys.exit("%s is %d bytes, expected %d (a 128K IPL image; merge "
                     "even/odd halves first)" % (args.ipl, len(ipl), IPL_LEN))
        chain_to = u32(ipl, RESET_PC_ADDR - IPL_BASE)
        if not (IPL_BASE <= chain_to < IPL_BASE + IPL_LEN):
            sys.exit("%s has reset PC $%08X, which is outside the ROM window "
                     "$%06X-$%06X -- this does not look like an IPL image"
                     % (args.ipl, chain_to, IPL_BASE, IPL_BASE + IPL_LEN - 1))
        if args.base is not None:
            testipl_base = args.base
        else:
            testipl_base, free_end = find_free(ipl)
            free_len = free_end - testipl_base
            if free_len < MIN_FREE:
                sys.exit(
                    "%s: largest unprogrammed run is %d bytes at $%06X, too "
                    "small for TEST-IPL.\n"
                    "Since the move to C the payload no longer fits a stock "
                    "Sharp IPL.  Free space by image:\n"
                    "    exbios    65536 bytes   supported\n"
                    "    X68030    49612 bytes   supported\n"
                    "    ACE        6668 bytes   too small\n"
                    "    XVI        8404 bytes   too small\n"
                    "    Compact    8120 bytes   too small\n"
                    "Inject into exbios or an X68030 IPL, or build standalone."
                    % (args.ipl, free_len, testipl_base))
        if testipl_base % 4:
            sys.exit("injection address $%06X is not longword aligned" % testipl_base)

    # --- compile and link ----------------------------------------------------
    preflight(srcdir)
    asm_defines = []
    c_defines = list(args.cdefine)
    if chain_to is not None:
        asm_defines.append("IPL_ENTRY=%d" % chain_to)
        c_defines.append("IPL_ENTRY=%d" % chain_to)

    objs = compile_sources(tools, srcdir, out, asm_defines, c_defines)
    script = out / "link.ld"
    write_linker_script(script, testipl_base)
    payload_path = out / "payload.bin"
    p = run([tools / "vlink", "-brawbin1", "-T", script, "-M",
             "-o", payload_path, *objs])
    (out / "link.map").write_text(p.stdout)
    check_map(p.stdout)

    payload = bytearray(payload_path.read_bytes())
    if len(payload) % 2:
        payload.append(FILL)

    # The header is patched blind, so prove it is where it should be.
    if payload[0:2] != b"\x60\x00":
        sys.exit("payload does not open with bra.w -- crt0.s did not link first")

    # --- lay out the ROM image ----------------------------------------------
    inj = testipl_base - IPL_BASE
    end = inj + len(payload)
    if end > IPL_LEN:
        sys.exit("payload is %d bytes and does not fit: $%06X+%d runs past $%06X"
                 % (len(payload), testipl_base, len(payload), IPL_BASE + IPL_LEN - 1))
    if ipl is not None and testipl_base + len(payload) > free_end:
        sys.exit("payload is %d bytes but only %d are free at $%06X in %s"
                 % (len(payload), free_end - testipl_base, testipl_base, args.ipl))

    if ipl is None:
        rom = bytearray([FILL]) * IPL_LEN
        rom[inj:end] = payload
        # The reset vector is the whole hand-off: the 68000 takes SSP and PC
        # from these two longwords and TEST-IPL does the rest itself.
        put32(rom, RESET_SSP_ADDR - IPL_BASE, STACK_TOP)
    else:
        # Refuse to inject over anything that is not fill: better a loud
        # failure than a ROM with a hole quietly punched in its code.
        target = ipl[inj:end]
        fill = target[0] if target else 0
        if fill not in (0x00, 0xFF) or any(b != fill for b in target):
            bad = next(i for i, b in enumerate(target) if b != fill)
            sys.exit("refusing to inject: $%06X is $%02X, not fill -- that "
                     "region is in use" % (IPL_BASE + inj + bad, target[bad]))
        rom = ipl
        rom[inj:end] = payload
        # The IPL's own SSP is left alone; only the PC is taken over.

    put32(rom, RESET_PC_ADDR - IPL_BASE, testipl_base)

    # --- fill in the ROM self-check ------------------------------------------
    # Computed last, over the finished image, skipping the field that stores it.
    rom_sum = sum32(rom, skip=inj + ROMSUM_OFF)
    put32(rom, inj + ROMSUM_OFF, rom_sum)

    # --- emit ----------------------------------------------------------------
    (out / "testipl.dat").write_bytes(rom)
    # even = D15-D8 = IC12, odd = D7-D0 = IC11
    (out / "testipl_even.bin").write_bytes(bytes(rom[0::2]))
    (out / "testipl_odd.bin").write_bytes(bytes(rom[1::2]))

    if ipl is None:
        spare = IPL_LEN - len(payload) - 0x10  # minus the vectors at the front
        print("standalone TEST-IPL ROM")
        print("TEST-IPL payload  %6d bytes  $%06X-$%06X  (%d bytes spare)"
              % (len(payload), testipl_base, IPL_BASE + end - 1, spare))
        print("reset SSP         $%08X" % STACK_TOP)
    else:
        print("TEST-IPL injected into %s" % args.ipl)
        print("TEST-IPL payload  %6d bytes  $%06X-$%06X  (%d bytes free)"
              % (len(payload), testipl_base, IPL_BASE + end - 1,
                 free_end - testipl_base))
        print("chains to         $%08X  (the IPL's own reset PC)" % chain_to)
    print("reset PC          $%08X" % testipl_base)
    print("ROM checksum      $%08X" % rom_sum)
    print()
    for name in ("testipl.dat", "testipl_even.bin", "testipl_odd.bin"):
        q = out / name
        print("  %-24s %8d bytes" % (name, q.stat().st_size))


if __name__ == "__main__":
    main()
