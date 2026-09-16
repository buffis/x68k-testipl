# Toolchain

`./get-tools.sh` fetches and builds all three into `tools/`, from Frank Wille's
sources. `build.py` drives them directly; the `vc` frontend is not used, so
there is no target config file to keep in step with `tools/`.

| tool | role |
|---|---|
| `vasmm68k_mot` | assembler, Motorola syntax. Also assembles vbcc's output. |
| `vbccm68k` | C compiler. Emits vasm Motorola-syntax assembly, not objects. |
| `vlink` | linker. `-brawbin1` + a `-T` script gives an absolute raw binary. |

## The pipeline

```sh
tools/vbccm68k  -cpu=68000 -sc -quiet foo.c -o=foo.asm
tools/vasmm68k_mot -Fvobj -m68000 -quiet -o foo.o foo.asm
tools/vlink -brawbin1 -T link.ld -M -o payload.bin crt0.o runtime.o foo.o ...
```

vbcc uses `-flag=value`, so it is `-o=foo.asm`, not `-o foo.asm`.

## Flags that matter

- `-cpu=68000` is the default, but pass it explicitly.
- `-sc` (small code) uses 16-bit PC-relative calls. Safe well under 32K; if the
  payload ever outgrows it vasm raises a branch-out-of-range **error**, not
  silence. That error means "drop `-sc`".
- **Not** `-sd` (small data): it claims `a4`, which the fault-recovery contract
  uses.
- **Not** `-const-in-data`: const data belongs in CODE (see below).

## Two properties this ROM depends on

**Constant data goes in the code section.** vbcc places const data in CODE by
default, so string literals need no writable data segment. A freshly compiled
file emits exactly one section, `section "CODE",code` — no `.data`, no `.bss`.
That matters because there is no RAM at reset to initialise them from.

**`volatile` is honoured locally.** vbcc brackets each volatile access with
`opt oc-` / `opt oc+`, disabling optimisation around it, so a write-then-read-
back of the same MMIO address survives. Verified: `MFP(16) = 0xA5; v = MFP(16);`
compiles to `move.b #$A5,$E88021` / `nop` / `move.b $E88021,d7`.

## Building vbcc non-interactively

vbcc's `dtgen` asks which host types implement each target type. `get-tools.sh`
feeds it **empty lines** to accept the defaults, which are right for a 64-bit
Linux host.

Two ways to get this wrong, both worth knowing:

- `yes y | make TARGET=m68k` answers the *type* questions with the literal
  string `y`, producing `#define l2zm(x) ((y)(x))` in `dt.h` and a pile of
  "'y' undeclared" errors.
- No stdin at all (`</dev/null`) makes dtgen loop on EOF **forever**, printing
  `Type y or n [y]:` until the disk fills.
