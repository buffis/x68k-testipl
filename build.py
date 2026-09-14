#!/usr/bin/env python3
"""
Build the X68000 POST ROM.

Two modes:

  standalone (default)
      Pads the assembled POST into a complete 128K image with the reset vector
      pointing at it.  It tests the machine, reports, and offers a rerun; it
      boots nothing, so the output contains only code from x68post.s.

  injected (--ipl FILE)
      Puts the POST into the unprogrammed space of an existing 128K IPL image,
      repoints the reset vector at it, and hands over to that IPL's original
      entry point when the tests are done.  Any IPL image works -- stock Sharp,
      exbios, anything else -- so long as it is 128K with a sane reset vector.

Either way it fills in the ROM self-check checksum and emits the 128K image
plus the even/odd halves for a pair of 27C512-class EPROMs.

Usage:  python3 build.py [--ipl FILE] [--out DIR] [--diag] [--vasm PATH]
"""

import argparse
import pathlib
import struct
import subprocess
import sys

# --- layout ------------------------------------------------------------------
IPL_BASE = 0xFE0000       # the IPL ROM window: $FE0000-$FFFFFF
IPL_LEN = 0x20000         # 128K, two 27C512-class devices
RESET_SSP_ADDR = 0xFF0000  # the 68000 fetches SSP from here at reset
RESET_PC_ADDR = 0xFF0004   # ...and its reset PC from here
POST_BASE = 0xFF0010       # code starts just past the two reset longwords
STACK_TOP = 0xE7FF00       # initial SSP; the POST re-derives its own anyway
FILL = 0xFF                # unprogrammed EPROM

ROMSUM_OFF = 4  # offset within the POST payload of the checksum field
                # (see the header comment in x68post.s)

# Test-harness metadata only -- the ROM image itself is model independent.
# MAME wants our image under the filename that machine's BIOS expects.
MODELS = {
    "compact": dict(ipl="iplromco.dat", machine="x68kxvi", bios="ipl12",
                    desc="X68000 Compact / XVI Compact"),
    "xvi":     dict(ipl="iplromxv.dat", machine="x68kxvi", bios="ipl11",
                    desc="X68000 SUPER / XVI"),
    "ace":     dict(ipl="iplrom.dat",   machine="x68000", bios="ipl10",
                    desc="X68000 / ACE / EXPERT / PRO"),
    "x68030":  dict(ipl="iplrom30.dat", machine="x68030", bios="ipl13",
                    desc="X68030"),
}


def u32(b, off):
    return struct.unpack_from(">I", b, off)[0]


def put32(b, off, v):
    struct.pack_into(">I", b, off, v & 0xFFFFFFFF)


def sum32(data, skip=None):
    """Sum of big-endian longwords, mod 2^32.  `skip` is a byte offset of one
    longword to leave out (the field holding the expected value itself)."""
    total = 0
    for off in range(0, len(data), 4):
        if skip is not None and off == skip:
            continue
        total += u32(data, off)
    return total & 0xFFFFFFFF


def find_free(ipl):
    """Largest run of a single fill byte ($00 or $FF) in a 128K IPL image, as a
    longword-aligned address.  The reset vector is excluded: on some images the
    SSP's leading zero bytes sit at the end of a long blank run and would
    otherwise be handed back as free space."""
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
    return IPL_BASE + best[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build")
    ap.add_argument("--vasm", default="./tools/vasmm68k_mot")
    ap.add_argument("--src", default="x68post.s")
    ap.add_argument("--ipl", metavar="FILE",
                    help="inject into this 128K IPL image and chain to it when "
                         "the tests finish, instead of building standalone")
    ap.add_argument("--base", type=lambda v: int(v, 0), metavar="ADDR",
                    help="with --ipl, force the injection address instead of "
                         "using the largest unprogrammed run")
    ap.add_argument("--diag", action="store_true",
                    help="build the diagnostic variant: after the normal run it "
                         "prints raw register and readback values for the RTC, "
                         "sprite RAM and CRTC probes instead of verdicts")
    args = ap.parse_args()

    # The checksum loop walks the ROM a longword at a time and skips the single
    # longword holding its own expected value, so that field has to be aligned.
    assert POST_BASE % 4 == 0, "POST_BASE must be longword aligned"
    assert (POST_BASE + ROMSUM_OFF) % 4 == 0

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    ipl = None
    post_base = POST_BASE
    chain_to = None
    if args.ipl:
        ipl = bytearray(pathlib.Path(args.ipl).read_bytes())
        if len(ipl) != IPL_LEN:
            sys.exit(f"{args.ipl} is {len(ipl)} bytes, expected {IPL_LEN} "
                     f"(a 128K IPL image; merge even/odd halves first)")
        chain_to = u32(ipl, RESET_PC_ADDR - IPL_BASE)
        if not (IPL_BASE <= chain_to < IPL_BASE + IPL_LEN):
            sys.exit(f"{args.ipl} has reset PC ${chain_to:08X}, which is outside "
                     f"the ROM window ${IPL_BASE:06X}-${IPL_BASE+IPL_LEN-1:06X} "
                     f"-- this does not look like an IPL image")
        post_base = args.base if args.base is not None else find_free(ipl)
        if post_base % 4:
            sys.exit(f"injection address ${post_base:06X} is not longword aligned")

    # --- assemble ------------------------------------------------------------
    payload_path = out / "x68post.bin"
    cmd = [args.vasm, "-Fbin", "-m68000", "-quiet", f"-DPOST_BASE={post_base}"]
    if chain_to is not None:
        cmd.append(f"-DIPL_ENTRY={chain_to}")
    if args.diag:
        cmd.append("-DDIAG=1")
    cmd += ["-o", str(payload_path), "-L", str(out / "x68post.lst"), args.src]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        sys.exit("vasm failed")
    if proc.stderr.strip():
        sys.stderr.write(proc.stderr)
    payload = bytearray(payload_path.read_bytes())
    if len(payload) % 2:
        payload.append(FILL)

    # --- lay out the ROM image ----------------------------------------------
    inj = post_base - IPL_BASE
    end = inj + len(payload)
    if end > IPL_LEN:
        sys.exit(f"payload is {len(payload)} bytes and does not fit: "
                 f"${post_base:06X}+{len(payload)} runs past ${IPL_BASE+IPL_LEN-1:06X}")

    if ipl is None:
        rom = bytearray([FILL]) * IPL_LEN
        rom[inj:end] = payload
        # The reset vector is the whole of the hand-off: the 68000 takes SSP and
        # PC from these two longwords and the POST does the rest itself.
        put32(rom, RESET_SSP_ADDR - IPL_BASE, STACK_TOP)
    else:
        # Refuse to inject over anything that is not fill: better a loud failure
        # than a ROM that quietly has a hole punched in its code.
        target = ipl[inj:end]
        fill = target[0] if target else 0
        if fill not in (0x00, 0xFF) or any(b != fill for b in target):
            bad = next(i for i, b in enumerate(target) if b != fill)
            sys.exit(f"refusing to inject: ${IPL_BASE + inj + bad:06X} is "
                     f"${target[bad]:02X}, not fill -- that region is in use")
        rom = ipl
        rom[inj:end] = payload
        # The IPL's own SSP is left alone; only the PC is taken over.

    put32(rom, RESET_PC_ADDR - IPL_BASE, post_base)

    # --- fill in the ROM self-check ------------------------------------------
    # Computed last, over the finished image, skipping the field that stores it.
    rom_sum = sum32(rom, skip=inj + ROMSUM_OFF)
    put32(rom, inj + ROMSUM_OFF, rom_sum)

    # --- emit ----------------------------------------------------------------
    (out / "ipl_post.dat").write_bytes(rom)
    # even = D15-D8 = IC12, odd = D7-D0 = IC11
    (out / "ipl_post_even.bin").write_bytes(bytes(rom[0::2]))
    (out / "ipl_post_odd.bin").write_bytes(bytes(rom[1::2]))

    tag = "  [DIAGNOSTIC BUILD]" if args.diag else ""
    if ipl is None:
        spare = IPL_LEN - len(payload) - 0x10  # minus the vectors at the front
        print(f"standalone POST ROM{tag}")
        print(f"POST payload      {len(payload):6d} bytes  "
              f"${post_base:06X}-${IPL_BASE + end - 1:06X}  "
              f"({spare} bytes spare)")
        print(f"reset SSP         ${STACK_TOP:08X}")
    else:
        print(f"POST injected into {args.ipl}{tag}")
        print(f"POST payload      {len(payload):6d} bytes  "
              f"${post_base:06X}-${IPL_BASE + end - 1:06X}")
        print(f"chains to         ${chain_to:08X}  (the IPL's own reset PC)")
    print(f"reset PC          ${post_base:08X}")
    print(f"ROM checksum      ${rom_sum:08X}")
    print()
    for name in ("ipl_post.dat", "ipl_post_even.bin", "ipl_post_odd.bin"):
        p = out / name
        print(f"  {name:24} {p.stat().st_size:8d} bytes")


if __name__ == "__main__":
    main()
