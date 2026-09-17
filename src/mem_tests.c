/*
 * mem_tests.c -- memory and ROM checksum tests.
 */
#include "testipl.h"

extern const u32 romsum_ref;    /* in crt0.s, at payload offset +4 */

/* Human68k SRAM signature: full-width X in Shift-JIS, then "68000W" */
static const u8 s_sramsig[8] = { 0x82, 0x77, '6', '8', '0', '0', '0', 'W' };

/*--- text VRAM -------------------------------------------------------------*/
/* Runs after video_init but before anything is printed, so all four planes
   are free to use.  The verdict is held in w_tvram and reported later, in
   memory order -- the display has to be trusted before the report means
   anything. */
int test_tvram(void)
{
    u32 n = (TVRAM_RESV - TVRAM) / 4;

    mem_fill(TVRAM, n);
    return mem_verify(TVRAM, n) ? V_FAIL : V_PASS;
}

/*--- CGROM checksum --------------------------------------------------------*/
/* Sums the whole 768K font ROM and compares against CGROM_SUM.  The value is
   printed in brackets either way, so a machine carrying a different revision
   gives you a number to record rather than a bare FAIL. */
int test_cgrom(void)
{
    u32 p = CGROM;
    u32 end = CGROM + CGROM_LEN;
    u32 sum = 0;

    while (p < end) {
        sum += MMIO32(p);
        p += 4;
    }
    w_sum = sum;
    w_sumshow = 1;
    return (sum == CGROM_SUM) ? V_PASS : V_FAIL;
}

/*--- IPL ROM checksum ------------------------------------------------------*/
/* Sums the whole 128K ROM except the longword holding the reference value, so
   the ROM verifies the code you are running.  This checks the EPROM burn, not
   the machine: the machine's own IPL is out of its socket while this one is in. */
int test_romsum(void)
{
    u32 p = IPLROM;
    u32 end = IPLROM + IPLROM_LEN;
    u32 skip = (u32)&romsum_ref;
    u32 sum = 0;

    while (p < end) {
        if (p != skip)
            sum += MMIO32(p);
        p += 4;
    }
    w_sum = sum;                        /* shown in brackets either way */
    w_sumshow = 1;
    return (sum == romsum_ref) ? V_PASS : V_FAIL;
}

/*--- graphic VRAM ----------------------------------------------------------*/
/* The 2MB graphic VRAM window folds onto 512K of real memory, and how it folds
   is set by CRTC R20 bits 8-11.  Switch to the mode that maps the first 512K
   through as plain 16-bit words, test it, then put R20 back for the display. */
int test_gvram(void)
{
    u32 n = (GVRAM_TEST_END - GVRAM) / 4;
    int bad;

    CRTC(20) = 0x0316;                  /* whole words, no nibble packing */
    mem_fill(GVRAM, n);
    bad = mem_verify(GVRAM, n);
    CRTC(20) = 0x0B16;                  /* back to the display mode */
    return bad ? V_FAIL : V_PASS;
}

/*
 * sprite_init: put the sprite/BG controller into a state that lets the CPU
 * reach sprite RAM.  The four timing registers get the values and order a stock
 * IPL writes, tapped from a live boot -- they read back $FF, so post-boot state
 * does not tell you what was programmed.  The control register must then get
 * $0000, not the $0010 an IPL leaves behind: bit 4 looks like a BG enable, and
 * a controller fetching from its own RAM will not let the CPU in.  Both are
 * needed.
 */
static void sprite_init(void)
{
    SPR_HDISP  = 0x00FF;
    SPR_HTOTAL = 0x00FF;
    SPR_VDISP  = 0x00FF;
    SPR_RES    = 0x00FF;
    SPRREG     = 0x0000;                /* all BG planes off */
}

/*--- sprite / PCG RAM ------------------------------------------------------
 * Sprite RAM is not reachable in every screen mode, and video_init picks one
 * where it is not: IOCS _SP_INIT ($FFC418 in the Compact IPL) opens with a
 * guard that reads CRTC R20 and refuses to touch sprite hardware when the low
 * byte is $16 -- exactly what video_init writes.  On real hardware a word read
 * of $EB8000 bus-errors at $0B16 and returns data at $0B15, so switch to $0B15
 * for the test.  The display is garbled while it runs, since the rest of the
 * CRTC timing still describes the old mode.  R20 is restored by the caller --
 * the only place that survives a bus error.
 */
int test_sprram(void)
{
    u32 n = (SPRRAM_END - SPRRAM) / 4;
    u16 saved;
    int bad;

    CRTC(20) = 0x0B15;
    nop_settle();
    saved = VC_R2;
    VC_R2 = 0x0020;                     /* text layer only */
    sprite_init();
    nop_settle();

    mem_fill(SPRRAM, n);
    bad = mem_verify(SPRRAM, n);

    VC_R2 = saved;
    return bad ? V_FAIL : V_PASS;
}

/*--- battery SRAM ----------------------------------------------------------*/
/* Read-only: SRAM holds the user's settings, so check the Human68k signature
   rather than writing to it.  A failure here normally means a flat backup
   battery and lost contents, not a bad chip -- the stock IPL re-initialises
   SRAM when it sees the same thing. */
int test_sram(void)
{
    int i;

    for (i = 0; i < 8; i++)
        if (MMIO8(SRAM + i) != s_sramsig[i])
            return V_FAIL;
    return V_PASS;
}

/* dram_tick: one dot per megabyte sized, so a machine that stalls part way
   through says where. */
void dram_tick(void)
{
    progress_char('.');
}

/* count_bits: population count. */
static int count_bits(u32 v)
{
    int n = 0;

    while (v) {
        if (v & 1)
            n++;
        v >>= 1;
    }
    return n;
}

/*--- main RAM: sizing ------------------------------------------------------
 * Tags each megabyte and reads every tag back, which catches both running off
 * the top and aliasing on a part-populated machine.  The result goes in
 * w_ramsize and is reported as this line's verdict, so the size is on screen
 * before the pattern pass below it starts.
 *
 * Every counter here is volatile: each phase is a recovery point, and a
 * non-volatile local would be restored to its setjmp-time value when a probe
 * runs off the top of memory and faults.
 */
int test_ramsize(void)
{
    volatile u32 mb;
    volatile u32 top;
    jmp_buf jb;
    u32 outer = w_jbp;
    volatile u32 bits;      /* written inside a guarded block and
                               read after it -- must not live in a
                               register longjmp would restore */
    u32 a, tag, lo, hi;

    /* The first kilobyte must work before exception vectors can be installed.
       No guard of our own here: a fault lands on run_test's FAIL path. */
    MMIO32(0) = 0xC3C35A5AUL;
    MMIO32(0x3FC) = 0xC3C35A5AUL;
    if (MMIO32(0) != 0xC3C35A5AUL || MMIO32(0x3FC) != 0xC3C35A5AUL) {
        /* Not V_SKIP: no memory at all is emphatically a FAIL. */
        w_ramsize = 0;
        return V_DEAD;
    }

    /*--- phase 1a: tag each megabyte.  A bus error here just means we have run
          off the top, so it is a normal end, not a failure. ---------------- */
    mb = 0;
    if (setjmp(jb) == 0) {
        w_jbp = (u32)&jb;
        for (mb = 0; mb < MAX_RAM_MB; mb++) {
            a = mb << 20;
            tag = 0xD0000000UL + mb;
            MMIO32(a) = tag;
            nop_settle();
            if (MMIO32(a) != tag)
                break;
            dram_tick();                /* serial only: where a hang was */
        }
    }
    w_jbp = outer;
    top = mb;
    if (top == 0) {
        w_ramsize = 0;
        return V_DEAD;
    }

    /*--- phase 1b: read every tag back, which is what catches aliasing.  On a
          part-populated machine high addresses fold back onto low memory, so
          each tag reads back fine when written but an earlier one has since
          been overwritten.  Only a second pass finds that. ----------------- */
    mb = 0;
    if (setjmp(jb) == 0) {
        w_jbp = (u32)&jb;
        for (mb = 0; mb < top; mb++) {
            a = mb << 20;
            tag = 0xD0000000UL + mb;
            if (MMIO32(a) != tag)
                break;
        }
    }
    w_jbp = outer;
    top = mb;
    if (top == 0) {
        w_ramsize = 0;
        return V_DEAD;
    }
    w_ramsize = top << 20;

    /*--- phase 1c: is the megabyte above the top absent, or present and
          faulty?  Sizing stops at the first megabyte whose tag does not read
          back, which happens both when nothing is there and when there is
          memory with a stuck bit -- left alone, a failing chip would quietly be
          reported as a smaller machine.  Memory that is present still stores
          most of what you write, so write all-zeroes and all-ones and count the
          bits that misbehave: a handful is a faulty device, everything means
          nothing is there. ------------------------------------------------ */
    if (top >= MAX_RAM_MB)
        return V_SIZE;

    a = top << 20;
    bits = 0;
    if (setjmp(jb) == 0) {              /* a fault here just means absent */
        w_jbp = (u32)&jb;
        MMIO32(a) = 0;
        nop_settle();
        lo = MMIO32(a);                 /* bits that would not go low */
        MMIO32(a) = 0xFFFFFFFFUL;
        nop_settle();
        hi = ~MMIO32(a);                /* bits that would not go high */
        bits = lo | hi;                 /* every bit that misbehaved */
    }
    w_jbp = outer;

    if (bits && count_bits(bits) <= 8) {
        /* The mask says which bits, and the bit numbers map onto the chips in
           that bank. */
        w_faddr = a;
        w_fgot = bits;
        w_fdetail = 2;
        return V_STUCK;
    }
    return V_SIZE;                      /* nothing there: the normal end */
}

/*--- main RAM: pattern test ------------------------------------------------
 * Everything above the vector table, filled then verified.  Runs after
 * test_ramsize, which is where w_ramsize comes from.
 */

/*
 * pmark: phase letter ('W' filling, 'V' verifying) and the address about to be
 * worked on, overwritten in place -- 80 slices per 10 MB would run off the end
 * of the line as marks but a number always fits, and it names the 8K block a
 * stall happened in.  Written before the slice, so the address on screen is the
 * one being worked on when it stops.  Serial gets a plain dot per slice; it has
 * no cursor to rewind.
 */
static void pmark(u32 letter, u32 addr)
{
    serial_char('.');

    if (w_addrcol == 0xFFFF) {
        w_addrcol = w_col;
        /* Claim the progress column too: this field is all test_dram prints, so
           with w_progcol left at $FFFF progress_clear would do nothing and the
           verdict would land after the address rather than over it. */
        w_progcol = w_col;
    }
    w_col = w_addrcol;                  /* back to the start of the field */

    putchar_at(letter, COL_NORMAL);
    putchar_at('$', COL_NORMAL);
    print_hex_scr(addr, 8);
}

/* The slice size only sets how precisely the on-screen address names a stall,
   and smaller slices cost real time: 512 adds about twelve seconds at 12 MB. */
#define SLICE 2048

int test_dram(void)
{
    u32 total, addr, left, n;

    if (w_ramsize == 0)
        return V_SKIP;                  /* sizing already failed and said why */

    /* Never pattern over our own stack: a7 still in main RAM means both stack
       probes failed, and patterning would overwrite the return addresses under
       it. */
    if (get_sp() < TVRAM)
        return V_SKIP;                  /* SKIP rather than self-destruct */

    total = (w_ramsize - 0x400) / 4;

    /* Fill everything before verifying anything, so aliasing between megabytes
       still shows up -- the slicing only exists to punctuate the display. */
    addr = 0x400;
    left = total;
    while (left) {
        n = (left > SLICE) ? SLICE : left;
        pmark('W', addr);
        mem_fill(addr, n);
        addr += n * 4;
        left -= n;
    }

    addr = 0x400;
    left = total;
    while (left) {
        n = (left > SLICE) ? SLICE : left;
        pmark('V', addr);
        if (mem_verify(addr, n))
            return V_FAIL;
        addr += n * 4;
        left -= n;
    }
    return V_PASS;
}

/*--- main RAM vs SRAM ------------------------------------------------------
 * Human68k records the memory size it last configured at $ED0008; comparing it
 * with what we measured catches a whole bank having gone missing.  The stock
 * IPL rewrites the value on every boot, so the mismatch only shows on the first
 * boot after the fault appears.  SKIP when SRAM holds nothing plausible, so an
 * unconfigured machine is not reported as broken.
 *
 * (MAME fakes that address from the configured RAM size rather than reading
 * NVRAM, so there it compares against the emulated machine's size.)
 */
int test_ramsize_sram(void)
{
    u32 v = MMIO32(SRAM + 8);

    if (v == 0)
        return V_SKIP;
    if (v > 0x00C00000UL)               /* more than 12MB is not credible */
        return V_SKIP;
    if (v & 0x000FFFFFUL)               /* must be a whole megabyte */
        return V_SKIP;
    return (v == w_ramsize) ? V_PASS : V_FAIL;
}
