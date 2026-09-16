/*
 * main.c -- work-area init, the test sequence, summary, hand-off.
 *
 * Entered from crt0.s with the display up, the stack validated and all 256
 * exception vectors installed.  Never returns.
 */
#include "testipl.h"

void cpu_halt(void);
#ifdef IPL_ENTRY
void chain_to_ipl(void);
#endif

static const char s_allok[]   = "ALL TESTS PASSED";
static const char s_failed[]  = " TEST(S) FAILED";
static const char s_halted[]  = "Testing done! You can shut down the computer.";
static const char s_booting[] = "EXITING";

static const char n_mfp[]     = "MFP MC68901";
static const char n_vidtim[]  = "CRTC video timing";
static const char n_rtc[]     = "RTC RP5C15";
static const char n_rtcosc[]  = "RTC oscillator";
static const char n_dmac[]    = "DMAC HD63450";
static const char n_opm[]     = "OPM YM2151";
static const char n_ppi[]     = "PPI i8255";
static const char n_fdc[]     = "FDC uPD72065";
static const char n_scsi[]    = "SCSI MB89352";   /* not on ACE/PRO/EXPERT */
static const char n_romsum[]  = "ROM checksum";
static const char n_cgrom[]   = "CGROM checksum";
static const char n_tvram[]   = "Text VRAM";
static const char n_gvram[]   = "Graphic VRAM";
static const char n_sprram[]  = "Sprite RAM";
static const char n_sram[]    = "SRAM signature";
static const char n_ramsize[] = "Main RAM size";
static const char n_dram[]    = "Main RAM";
static const char n_ramchk[]  = "Main RAM vs SRAM";

void testipl_main(void)
{
    u16 tvram_verdict;

    /* The work area lives in text VRAM, so it only holds up once the display is
       scanning -- hence here rather than in crt0, where it would have to
       survive the whole of test_tvram unrefreshed. */
    w_fail = 0;
    w_ramsize = 0;
    w_col = LEFT_MARGIN;
    w_row = 0;
    w_addrcol = 0xFFFF;
    w_progcol = 0xFFFF;
    w_sumshow = 0;
    w_fdetail = 0;          /* the Text VRAM line bypasses run_test, so
                               nothing else would clear it */

    serial_init();
    serial_str(s_banner);
    serial_crlf();

    /* Decided before anything can be printed: the display has to be trusted
       before the report means anything. */
    tvram_verdict = (u16)test_tvram();
    w_tvram = tvram_verdict;

    tvram_clear();

    print_str(s_banner, COL_NORMAL);
    newline();
    newline();

    /*=====================================================================
     * the tests
     *
     * Devices first, then memory: main RAM is the slowest test and the one
     * most likely to hang a sick machine, so by the time it runs the rest of
     * the report is already on screen.
     *===================================================================*/

    /*--- devices ---------------------------------------------------------*/
    run_test(n_mfp, test_mfp);
    run_test(n_vidtim, test_vidtiming);
    run_test(n_rtc, test_rtc);
    run_test(n_rtcosc, test_rtcosc);
    run_test(n_dmac, test_dmac);
    run_test(n_opm, test_opm);
    run_test(n_ppi, test_ppi);
    run_test(n_fdc, test_fdc);
    run_test_opt(n_scsi, test_scsi);

    /*--- memory ----------------------------------------------------------*/
    run_test(n_romsum, test_romsum);
    run_test(n_cgrom, test_cgrom);

    /* Verdict was worked out at startup, before anything could be printed. */
    line_start(n_tvram);
    verdict(w_tvram);

    run_test(n_gvram, test_gvram);

    /* Optional: sprite RAM does not answer the bus in every screen mode, so a
       fault here reads SKIP.  RAM that answers with the wrong pattern still
       FAILs.  R20 is restored here rather than inside the test, because this is
       the only place that survives a bus error. */
    run_test_opt(n_sprram, test_sprram);
    CRTC(20) = 0x0B16;
    nop_settle();

    run_test(n_sram, test_sram);

    /* Size first, so the machine's memory is on screen before the slow part
       starts; then the pattern test; then the cross-check against what SRAM
       says. */
    run_test(n_ramsize, test_ramsize);
    run_test(n_dram, test_dram);
    run_test(n_ramchk, test_ramsize_sram);

    /*=====================================================================
     * summary, then stop
     *===================================================================*/
    newline();
    if (w_fail == 0) {
        print_str(s_allok, COL_GOOD);
        serial_str(s_allok);
        serial_crlf();
    } else {
        print_dec(w_fail, COL_BAD);
        print_str(s_failed, COL_BAD);
        serial_str(s_failed);
        serial_crlf();
    }

#ifdef IPL_ENTRY
    /* Hold long enough for the report to be read, then hand over: the IPL
       clears the screen on its way to booting, so without a pause the run would
       flash past.  A failing run holds longer.  The serial log has it all
       either way. */
    delay_seconds((w_fail != 0) ? 10 : 3);
    serial_str(s_booting);
    serial_crlf();
    serial_drain();                     /* or the IPL's SCC reset eats it */
    chain_to_ipl();
#else
    /* Nothing to hand over to, so stop with the report up. */
    newline();
    print_str(s_halted, COL_NORMAL);
    serial_str(s_halted);
    serial_crlf();
    cpu_halt();
#endif
}
