/*
 * serial.c -- RS-232C on SCC channel A.
 *
 * SCC PCLK is 5MHz; time constant = PCLK / (2 * baud * 16) - 2.
 *
 * MAME's x68000 driver wires SCC channel B to the mouse and leaves channel A's
 * TxD unconnected, so this path cannot be observed under emulation; the harness
 * watches writes to $E98007 instead.
 */
#include "testipl.h"

#define SCC_TC  14              /* ~9600 baud, 8N1 */

/*
 * The init sequence is a table rather than a run of stores so that its ORDER is
 * data, and stays diffable against the assembly it came from.  Order matters:
 * the transmitter must not be enabled until its clock source is configured, or
 * it latches a rate of zero and never reports ready.  Nothing in MAME can catch
 * a reordering here -- channel A's TxD is not connected -- so the table is the
 * only guard there is.
 */
static const u8 scc_init_seq[] = {
     4, 0x44,       /* WR4  x16 clock, 1 stop, no parity */
     3, 0xC0,       /* WR3  rx 8 bits, rx still disabled */
     5, 0x60,       /* WR5  tx 8 bits, tx still disabled */
    11, 0x50,       /* WR11 tx and rx clock from BRG */
    14, 0x00,       /* WR14 BRG off while loading it */
    12, (SCC_TC & 0xFF),   /* WR12 time constant, low */
    13, (SCC_TC >> 8),     /* WR13 time constant, high */
    14, 0x03,       /* WR14 BRG on, source = PCLK */
     3, 0xC1,       /* WR3  rx enable */
     5, 0x68        /* WR5  tx enable */
};

void serial_init(void)
{
    int i;
    u32 n;

    w_serial = 1;               /* assume dead until proven alive */

    /* WR9 force hardware reset, then settle before programming anything else. */
    SCC_ACTL = 9;
    SCC_ACTL = 0xC0;
    for (n = 0; n < 64; n++)
        nop_settle();

    for (i = 0; i < (int)sizeof(scc_init_seq); i += 2) {
        SCC_ACTL = scc_init_seq[i];
        SCC_ACTL = scc_init_seq[i + 1];
    }

    /* Bounded wait for the transmitter to report ready.  If it never does,
       leave serial disabled rather than stalling every line of output on a
       machine whose SCC is dead or absent. */
    for (n = 0x1000; n; n--) {
        if (SCC_ACTL & 0x04) {  /* RR0 bit 2 = tx buffer empty */
            w_serial = 0;
            return;
        }
    }
}

/* serial_char: bounded wait, so a dead SCC cannot hang the run. */
void serial_char(u32 c)
{
    u32 n;

    if (w_serial != 0)
        return;
    for (n = 0x1000; n; n--) {
        if (SCC_ACTL & 0x04) {
            SCC_ADATA = (u8)c;
            return;
        }
    }
}

void serial_str(const char *s)
{
    while (*s)
        serial_char((u8)*s++);
}

void serial_crlf(void)
{
    serial_char(13);
    serial_char(10);
}

/*
 * serial_drain: wait until the transmitter has actually shifted the last byte
 * onto the wire, not merely accepted it.
 *
 * serial_char waits for "tx buffer empty" (RR0 bit 2) before writing, which
 * frees the holding register while the previous byte is still in the shift
 * register, so up to two are still in flight when the final character returns.
 * Standalone that is harmless -- the CPU parks in STOP and they drain on their
 * own -- but the injected build jumps straight to the IPL, which resets the SCC
 * and cuts them off mid-transmission; on real hardware that lost the tail of
 * the last line.
 *
 * RR1 bit 0 is All Sent.  The SCC's register pointer auto-clears after each
 * access, so register 1 has to be re-selected on every poll.  Bounded like
 * every other wait here: a dead SCC must not hold the machine off the IPL.
 */
void serial_drain(void)
{
    u32 n;

    if (w_serial != 0)
        return;
    for (n = 0x8000; n; n--) {
        SCC_ACTL = 1;                   /* point at RR1 */
        if (SCC_ACTL & 0x01)            /* bit 0 = All Sent */
            return;
    }
}
