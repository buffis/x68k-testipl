/*
 * report.c -- test dispatch and result line formatting.
 */
#include "testipl.h"

const char s_banner[] = "SHARP X68000  TEST-IPL  v0.36";

static const char s_ok[]     = "OK";
static const char s_fail[]   = "FAIL";
static const char s_skip[]   = "SKIP";
static const char s_kb[]     = "K";
static const char s_indent[] = "  ";
static const char s_exp[]    = " exp ";
static const char s_got[]    = " got ";
static const char s_stuck[]  = " stuck bits ";
static const char s_lparen[] = " (";
static const char s_rparen[] = ")";

/*
 * progress_char: to screen and serial.  Remembers the column the run started at
 * so the marks can be wiped before the verdict is printed -- otherwise they
 * push it out of its column and the report stops lining up.
 */
void progress_char(u32 ch)
{
    if (w_progcol == 0xFFFF)
        w_progcol = w_col;
    putchar_at(ch, COL_NORMAL);
    serial_char(ch);
}

/*
 * progress_clear: wipe the marks and put the cursor back where they started.
 * The serial log keeps them: no cursor to rewind, and a log showing how far a
 * run got is the point of them.
 */
void progress_clear(void)
{
    u16 start = w_progcol;
    int n;

    if (start == 0xFFFF)
        return;
    n = (int)w_col - (int)start;
    w_col = start;
    while (n-- > 0)
        putchar_at(' ', COL_NORMAL);
    w_col = start;
    w_progcol = 0xFFFF;
}

/*
 * line_start: prints the test name and pads with dots so every verdict lands in
 * the same column, on screen and on the serial line.
 */
void line_start(const char *name)
{
    print_str(name, COL_NORMAL);
    serial_str(name);
    while (w_col < RESULT_COL) {
        putchar_at('.', COL_NORMAL);
        serial_char('.');
    }
    putchar_at(' ', COL_NORMAL);
    serial_char(' ');
}

/* print_ramsize: writes the detected size, e.g. 4096K, where a verdict would
   go.  Called from verdict, so the line is already started. */
static void print_ramsize(void)
{
    print_dec(w_ramsize >> 10, COL_NORMAL);
    print_str(s_kb, COL_NORMAL);
    serial_str(s_kb);
}

/* print_sum: appends " (xxxxxxxx)" to a verdict when the test set w_sumshow.
   Used by the two checksum lines, which report a value as well as a verdict. */
static void print_sum(void)
{
    if (w_sumshow == 0)
        return;
    w_sumshow = 0;
    detail_str(s_lparen);
    print_hex(w_sum, 8);
    detail_str(s_rparen);
}

/*
 * Indented continuation under a FAIL.  Both kinds open with the address and
 * close with w_fgot, so only the middle differs:
 *   $00123456 exp $5A5AA5A5 got $5A5AA5A4
 *   $00100000 stuck bits $00000040
 */
static void print_detail(void)
{
    u16 kind = w_fdetail;

    w_fdetail = 0;
    detail_str(s_indent);
    print_hexdollar(w_faddr, 8);
    if (kind == 2) {
        detail_str(s_stuck);
    } else {
        detail_str(s_exp);
        print_hexdollar(w_fexp, 8);
        detail_str(s_got);
    }
    print_hexdollar(w_fgot, 8);
    newline();
    serial_crlf();
}

/*
 * verdict: 0 pass, 2 skip, 6 the RAM size line, anything else fail.
 * Only a fail is counted.
 */
void verdict(u32 v)
{
    progress_clear();

    if (v == V_SIZE) {
        /* Not a pass/fail: the line reports how much memory was found, and the
           pattern test on the next line is what passes or fails on it. */
        print_ramsize();
    } else if (v == V_SKIP) {
        print_str(s_skip, COL_NORMAL);
        serial_str(s_skip);
    } else if (v == V_PASS) {
        print_str(s_ok, COL_GOOD);
        serial_str(s_ok);
    } else {
        print_str(s_fail, COL_BAD);
        serial_str(s_fail);
        w_fail = w_fail + 1;
    }

    print_sum();
    newline();
    serial_crlf();

    if (w_fdetail != 0)
        print_detail();
}

/*
 * run_test / run_test_opt: prints the name, establishes bus-error recovery
 * around the call, runs the test and prints the verdict.  A bus error means
 * nothing responded at all: run_test calls that FAIL, run_test_opt SKIP, for
 * genuinely optional hardware.  Either way a device that answers but returns
 * bad data fails on its data.
 *
 * Every local here is volatile.  fault_handler longjmps out of the body, and a
 * non-volatile local would be restored to its setjmp-time value on the way
 * back -- which is the whole class of bug this arrangement invites.
 */
static void run_test_common(const char *name, int (*body)(void), u32 faultv)
{
    volatile u32 v;
    jmp_buf jb;

    w_fverdict = (u16)faultv;
    w_fdetail = 0;
    w_sumshow = 0;
    w_progcol = 0xFFFF;
    w_addrcol = 0xFFFF;

    line_start(name);

    if (setjmp(jb) == 0) {
        w_jbp = (u32)&jb;
        v = (u32)body();
    } else {
        /* The verdict a fault produces lives in memory, not in the longjmp
           value, so a nested probe that only cares "did this fault" does not
           have to carry one. */
        v = w_fverdict;
    }
    w_jbp = 0;

    verdict(v);
}

void run_test(const char *name, int (*body)(void))
{
    run_test_common(name, body, V_FAULT);
}

void run_test_opt(const char *name, int (*body)(void))
{
    run_test_common(name, body, V_SKIP);
}
