/*
 * dev_tests.c -- the memory-mapped device tests.
 *
 * Every access goes through the hw.h accessors, which are volatile.  These
 * tests are write-then-read-back-the-same-address, the exact pattern an
 * optimiser deletes, and a deleted read-back passes on dead hardware.
 */
#include "testipl.h"

/*--- MC68901 MFP -----------------------------------------------------------*/
/* Timer B is stopped, so its data register behaves as scratch.  Two
   complementary patterns, so a bus line stuck either way cannot pass. */
int test_mfp(void)
{
    u8 v;

    MFP(13) = 0;                /* TBCR = 0, stop timer B */

    MFP(16) = 0xA5;             /* TBDR */
    nop_settle();
    v = MFP(16);
    if (v != 0xA5)
        return V_FAIL;

    MFP(16) = 0x5A;
    nop_settle();
    v = MFP(16);
    if (v != 0x5A)
        return V_FAIL;

    MFP(16) = 0;
    return V_PASS;
}

/*--- CRTC liveness, via the MFP GPIP video timing inputs --------------------
 * The CRTC register file is write-only on real silicon -- R00/R04 read back
 * $0000 while the screen is plainly being scanned -- so no readback test of it
 * can work.  Ask the MFP instead: the CRTC drives V-DISP into GPIP bit 4 and
 * H-SYNC into bit 7, so either one toggling proves it is generating timing.
 *
 * Sample the port hard, accumulating OR and AND; OR & ~AND is the set of bits
 * that changed.  An undriven bus reads all-ones constantly, so it cancels out
 * and reads as dead rather than as live data.
 *
 * GPIP bit 6 (raster interrupt) is deliberately out of the mask: it only
 * toggles once a raster line has been programmed.  For the same reason one of
 * the two signals is enough.
 *
 * Exits as soon as both bits move, about one frame; the counter only bounds the
 * dead case.  V-DISP toggles once per ~18 ms, so the window must span a frame:
 * 40000 iterations is ~200 ms at 10 MHz, ~60 ms on a 25 MHz 68030.
 */
int test_vidtiming(void)
{
    u32 acc_or = 0;
    u32 acc_and = 0xFFFFFFFFUL;
    u32 moved = 0;
    u32 n;

    for (n = 40000; n; n--) {
        u32 s = MFP_GPIP;
        acc_or |= s;
        acc_and &= s;
        moved = (acc_or & ~acc_and) & GPIP_VID;
        if (moved == GPIP_VID)
            return V_PASS;              /* both signals seen, stop early */
    }
    return moved ? V_PASS : V_FAIL;     /* window expired: either one? */
}

/*--- RP5C15 RTC: is the chip there and does its bus work? -------------------
 * Bank 1 holds the alarm registers, which are plain storage and do not depend
 * on the oscillator.  Select bank 1, write $5 then $A to alarm register 2 and
 * read each back.  Proves the register file and the bus and nothing else --
 * whether the clock runs is test_rtcosc's problem.  Deliberately not a BCD
 * sanity check on the time registers: a clock frozen at a plausible time would
 * pass that.
 */
int test_rtc(void)
{
    u8 m, a, b;

    m = RTC_MODE;
    m &= (RTC_ALARM_EN | RTC_TIMER_EN);
    RTC_MODE = (u8)(m | RTC_BANK);      /* bank 1, leave the rest alone */
    nop_settle();

    RTC(2) = 0x05;
    nop_settle();
    a = RTC(2) & 0x0F;

    RTC(2) = 0x0A;
    nop_settle();
    b = RTC(2) & 0x0F;

    /* Back to bank 0 before judging, so the chip is left as it was found. */
    m = RTC_MODE;
    RTC_MODE = (u8)(m & (RTC_ALARM_EN | RTC_TIMER_EN));
    nop_settle();

    if (a != 0x05 || b != 0x0A)
        return V_FAIL;
    return V_PASS;
}

/* rtc_secs: the seconds registers, tens and units, one nibble each. */
static u32 rtc_secs(void)
{
    u32 t = RTC(1) & 0x0F;              /* seconds, tens */
    u32 u = RTC(0) & 0x0F;              /* seconds, units */
    return (t << 4) | u;
}

/*--- RP5C15 oscillator: does the clock actually advance? --------------------
 * A dead 32.768 kHz crystal, or battery corrosion around it, is the classic
 * X68000 failure and nothing above would notice: the registers keep whatever
 * they were left holding.  Read the seconds, wait, read again.
 *
 * Timer-enable is set first -- a clock merely switched off is a different fault
 * from a dead oscillator, and MAME comes up with the bit clear.
 *
 * Timed by counting V-DISP frames, not delay_seconds: that is calibrated for a
 * 10 MHz 68000 and runs several times faster on an X68030, while frames are
 * ~55 Hz whatever the CPU does.  With no CRTC scanning there are no frames and
 * it falls back to delay_seconds -- such a machine has already failed the video
 * timing test a line earlier.
 */
int test_rtcosc(void)
{
    u32 first;
    int i;

    RTC_MODE = (u8)((RTC_MODE & (RTC_ALARM_EN | RTC_TIMER_EN)) | RTC_TIMER_EN);
    nop_settle();

    first = rtc_secs();
    for (i = 0; i < 4; i++) {           /* four goes at about 1.1 s each */
        progress_char('.');
        if (!wait_frames(60))
            delay_seconds(1);           /* no video timing to count */
        if (rtc_secs() != first)
            return V_PASS;
    }
    return V_FAIL;                      /* never moved */
}

/*--- HD63450 DMAC ----------------------------------------------------------*/
/* Channel 0 is idle at reset, so its memory address register reads back what is
   written, proving the device is decoded and alive. */
int test_dmac(void)
{
    u32 v;

    DMAC32(0x0C) = 0x00A5A55AUL;        /* ch0 MAR */
    nop_settle();
    v = DMAC32(0x0C) & 0x00FFFFFFUL;    /* the MAR is 24 bits wide */
    if (v != 0x00A5A55AUL)
        return V_FAIL;

    DMAC32(0x0C) = 0x005AA5A5UL;
    nop_settle();
    v = DMAC32(0x0C) & 0x00FFFFFFUL;
    if (v != 0x005AA5A5UL)
        return V_FAIL;

    DMAC32(0x0C) = 0;
    return V_PASS;
}

/*--- YM2151 OPM ------------------------------------------------------------*/
/* BUSY is only asserted while the chip processes a register write, so idle it
   must read clear.  Minimal, but a real signal rather than a float -- a
   floating bus reads $FF, which has bit 7 set and therefore fails. */
int test_opm(void)
{
    if (OPM(1) & 0x80)                  /* status register, BUSY */
        return V_FAIL;
    return V_PASS;
}

/*--- MSM6258 ADPCM ---------------------------------------------------------
 * Not tested.  Its only readable register leaves most bits open, so on real
 * hardware the read returns bus float -- a healthy PRO gives $FF on one boot
 * and $C0 on the next.  Proving it alive needs a command and an observed state
 * change, which is more than this ROM can do between reset and handing over.
 */

/*--- uPD72065 FDC ----------------------------------------------------------*/
/* The defined idle state: RQM set, DIO clear, not busy.  Passive by design --
   a self test between reset and handover cannot safely drive a seek. */
int test_fdc(void)
{
    if ((FDC(0) & 0xD0) != 0x80)        /* main status register */
        return V_FAIL;
    return V_PASS;
}

/*--- MB89352 SCSI ----------------------------------------------------------
 * Internal SCSI only exists on the SUPER, XVI, Compact and X68030; the original
 * machine, ACE, EXPERT and PRO have SASI at $E96000 and nothing at $E96020.
 * BDID reports the host adapter's own ID as a single one-hot bit, so $00 or $FF
 * means nothing is answering and the controller is not fitted -- SKIP, not a
 * fault.  One that is present but broken still drives the bus and fails the
 * one-hot check.
 */
int test_scsi(void)
{
    u32 id = SCSI(0);                   /* BDID */

    if (id == 0x00 || id == 0xFF)
        return V_SKIP;
    if ((id - 1) & id)                  /* clears the single set bit */
        return V_FAIL;
    return V_PASS;
}

/*--- i8255 PPI -------------------------------------------------------------*/
/* Port C is the joystick-select output port, so configured as output it reads
   back the last value written.  Complementary nibbles, so a stuck line cannot
   pass.  Port C is restored to all-lines-high either way. */
int test_ppi(void)
{
    u8 a, b;

    PPI(3) = 0x92;                      /* mode 0: A in, B in, C out */
    nop_settle();

    PPI(2) = 0x0A;
    nop_settle();
    a = PPI(2) & 0x0F;

    PPI(2) = 0x05;
    nop_settle();
    b = PPI(2) & 0x0F;

    PPI(2) = 0x0F;                      /* all lines high, joysticks idle */

    if (a != 0x0A || b != 0x05)
        return V_FAIL;
    return V_PASS;
}
