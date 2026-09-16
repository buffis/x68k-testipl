/*
 * video.c -- CRTC, video controller, palette.
 *
 * The CRTC register file is WRITE ONLY on real silicon: R00, R04 and R20 all
 * read back $0000 on a machine visibly scanning a correct 768x512 display.
 * Nothing here reads one back, and nothing should start.
 */
#include "testipl.h"

/* The register values the stock IPL programs for CRTMOD 16 (768x512, 96x32
   text), read back from a live boot of the stock ROM. */
static const u16 crtc_tab[9] = {
    0x0089,                                 /* R00 horizontal total */
    0x000E, 0x001C, 0x007C,                 /* R01..R03 horizontal timing */
    0x0237, 0x0005, 0x0028, 0x0228,         /* R04..R07 vertical timing */
    0x001B                                  /* R08 horizontal adjust */
};

void video_init(void)
{
    int i;

    /* Monitor contrast is zero out of reset and the display stays blank until
       it is set -- the stock IPL loads it from SRAM at $FF00D4, long after we
       run.  Wind it to maximum: a diagnostic screen should be readable whatever
       the user's saved preference is, and the stock IPL restores their setting
       when we hand over. */
    SYSPORT(0) = 0x0F;

    CRTC(0) = crtc_tab[0];
    for (i = 1; i <= 8; i++)
        CRTC(i) = crtc_tab[i];
    for (i = 9; i <= 19; i++)
        CRTC(i) = 0;

    CRTC(20) = 0x0B16;          /* memory / display mode */
    CRTC(21) = 0;               /* no simultaneous plane access */
    CRTC(22) = 0;
    CRTC(23) = 0;
    CRTC(24) = 0;

    VC_R0 = 0x0003;             /* 768x512, 16 colours */
    VC_R1 = 0x06E4;             /* text above graphics */
    VC_R2 = 0x0020;             /* text layer on, everything else off */

    /* text palette: 0 background, 1 white, 2 green, 3 red */
    TPAL(0) = 0x0000;
    TPAL(1) = 0xFFFE;
    TPAL(2) = 0xF800;
    TPAL(3) = 0x07C0;
}

/*
 * wait_scanning: block until the CRTC is really scanning, or give up.  Watches
 * V-DISP on the MFP GPIP go high then low a few times, a frame each.  Bounded
 * at every step: a CRTC that never scans must not hang the run, and
 * test_vidtiming reports that case properly a few lines later.
 */
void wait_scanning(void)
{
    int f;
    u32 n;

    for (f = 0; f < 5; f++) {           /* five frames is ~90 ms at 55 Hz */
        for (n = 200000; n; n--)
            if (MFP_GPIP & GPIP_VDISP)
                break;
        if (!n)
            return;                     /* never came up: not scanning */
        for (n = 200000; n; n--)
            if (!(MFP_GPIP & GPIP_VDISP))
                break;
        if (!n)
            return;                     /* stuck high: not scanning */
    }
}

/*
 * wait_frames: returns 0 if the video timing never moved and the wait was
 * therefore not real time.  Bounded at every step, so a CRTC that is not
 * scanning cannot hang the run.
 */
int wait_frames(u32 frames)
{
    u32 n;

    while (frames--) {
        /* low first, then high -- one full edge pair per frame.  (The
           opposite order to wait_scanning, which is looking for the display
           to come up rather than counting frames.) */
        for (n = 200000; n; n--)
            if (!(MFP_GPIP & GPIP_VDISP))
                break;
        if (!n)
            return 0;
        for (n = 200000; n; n--)
            if (MFP_GPIP & GPIP_VDISP)
                break;
        if (!n)
            return 0;
    }
    return 1;
}

void tvram_clear(void)
{
    mem_clear(TVRAM, (TVRAM_RESV - TVRAM) / 4);
}
