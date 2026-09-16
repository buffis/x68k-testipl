/*
 * hw.h -- device addresses, MMIO accessors and the work area.
 *
 * EVERY hardware access in this ROM goes through the accessors here.  No .c
 * file outside this header may cast a pointer or name a device address:
 * build.py enforces both with a grep.  The reason is that nearly every device
 * test is write-then-read-back-the-same-address, which is exactly the pattern
 * an optimiser deletes -- and a deleted read-back does not fail loudly, it
 * makes the test pass on dead hardware.
 */
#ifndef HW_H
#define HW_H

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;

#define MMIO8(a)   (*(volatile u8  *)(u32)(a))
#define MMIO16(a)  (*(volatile u16 *)(u32)(a))
#define MMIO32(a)  (*(volatile u32 *)(u32)(a))

/* Most X68000 peripherals are wired to D7-D0 only, so register n lives at
   BASE + 1 + 2n and byte accesses to the even address hit nothing. */
#define ODDREG(base, n)  MMIO8((base) + 1 + 2 * (n))

/*--- memory regions --------------------------------------------------------*/
#define GVRAM           0x00C00000UL
#define GVRAM_TEST_END  0x00C80000UL    /* 512K of real memory */
#define TVRAM           0x00E00000UL    /* 4 planes, 128K each, contiguous */
#define TVRAM_RESV      0x00E7F000UL    /* stack + work area live above here */
#define TVRAM_PLANE     0x00020000UL
#define SPRRAM_END      0x00EC0000UL
#define SRAM            0x00ED0000UL
#define CGROM           0x00F00000UL
#define CGROM_LEN       0x000C0000UL
#define CGROM_SUM       0x13C64BFEUL    /* confirmed on a real PRO */
#define ANK8X16         0x00F3A800UL    /* 8x16 half-width font, 16 bytes/char */
#define IPLROM          0x00FE0000UL
#define IPLROM_LEN      0x00020000UL

/* Sprite RAM base is overridable so regress.sh can point it at an odd address
   and force the optional-test bus-error path.  Replaces a sed on the source. */
#ifndef SPRRAM
#define SPRRAM          0x00EB8000UL
#endif

/*--- devices ---------------------------------------------------------------*/
#define AREASET         0x00E86001UL    /* supervisor area set, odd lane */

#define CRTC(n)         MMIO16(0x00E80000UL + 2 * (n))   /* WRITE ONLY: the
                            register file does not read back on real silicon */
#define TPAL(n)         MMIO16(0x00E82200UL + 2 * (n))
#define VC_R0           MMIO16(0x00E82400UL)
#define VC_R1           MMIO16(0x00E82500UL)
#define VC_R2           MMIO16(0x00E82600UL)

#define DMAC8(off)      MMIO8 (0x00E84000UL + (off))
#define DMAC32(off)     MMIO32(0x00E84000UL + (off))

#define MFP(n)          ODDREG(0x00E88000UL, n)
#define MFP_GPIP        MFP(0)          /* video timing inputs */
#define GPIP_VDISP      0x10            /* bit 4, driven by the CRTC */
#define GPIP_HSYNC      0x80            /* bit 7, driven by the CRTC */
#define GPIP_VID        (GPIP_VDISP | GPIP_HSYNC)

#define RTC(n)          ODDREG(0x00E8A000UL, n)
#define RTC_MODE        RTC(13)
#define RTC_BANK        0x01            /* bit 0 register bank */
#define RTC_ALARM_EN    0x04            /* bit 2 alarm enable */
#define RTC_TIMER_EN    0x08            /* bit 3 -- the clock only advances
                                           while this is set */
#define SYSPORT(n)      ODDREG(0x00E8E000UL, n)
#define OPM(n)          ODDREG(0x00E90000UL, n)
#define FDC(n)          ODDREG(0x00E94000UL, n)
#define SCSI(n)         ODDREG(0x00E96020UL, n)
#define SCC_ACTL        MMIO8(0x00E98005UL)     /* channel A = RS-232C */
#define SCC_ADATA       MMIO8(0x00E98007UL)
#define PPI(n)          ODDREG(0x00E9A000UL, n)

#define SPRREG          MMIO16(0x00EB0808UL)    /* BG / sprite control */
#define SPR_HTOTAL      MMIO16(0x00EB080AUL)
#define SPR_HDISP       MMIO16(0x00EB080CUL)
#define SPR_VDISP       MMIO16(0x00EB080EUL)
#define SPR_RES         MMIO16(0x00EB0810UL)

#define MAX_RAM_MB      12              /* the address space tops out here */
#define MEM_XOR         0x5A5AA5A5UL    /* address-derived fill pattern */

/*--- screen ----------------------------------------------------------------*/
#define SCR_ROWS        32              /* 512 / 16 */
#define TV_STRIDE       128             /* bytes per scanline in a text plane */
#define COL_NORMAL      1               /* plane 0        -> white */
#define COL_GOOD        2               /* plane 1        -> green */
#define COL_BAD         3               /* plane 0 and 1  -> red */
#define RESULT_COL      30              /* column every verdict lands on */
/* Every line starts one column in: a real monitor overscans and the leftmost
   column is the one a badly adjusted set cuts off. */
#define LEFT_MARGIN     1

/*--- stack and work area, in the reserved top 4K of text VRAM ---------------
 * Both start at $E7FF00: the stack grows down through $E7F000-$E7FEFF, the
 * work area grows up.  Main RAM is under test and graphic VRAM folds onto
 * itself, so text VRAM is the only flat memory here that is not a test subject.
 *
 * w_col and w_row MUST stay at WORK+0 and WORK+2.  The MAME harness scripts
 * read the cursor straight out of $E7FF00/$E7FF02 to tell when a run has
 * finished; move them and the harness silently never decides a run is done.
 */
#define STACK_TOP       0x00E7FF00UL
#define WORK            0x00E7FF00UL

#define W16(off)        MMIO16(WORK + (off))
#define W32(off)        MMIO32(WORK + (off))

#define w_col       W16(0)      /* cursor column */
#define w_row       W16(2)      /* cursor row */
#define w_fail      W16(4)      /* failure count */
#define w_tvram     W16(6)      /* TVRAM verdict, decided before video is up */
#define w_serial    W16(8)      /* non-zero once serial is given up on */
#define w_fverdict  W16(10)     /* verdict to use if a test faults */
#define w_progcol   W16(12)     /* column a run of progress marks began at,
                                   $FFFF when none is open */
#define w_addrcol   W16(14)     /* column test_dram's address field sits at */
#define w_fdetail   W16(16)     /* detail line kind: 0 none, 1 exp/got, 2 stuck */
#define w_sumshow   W16(18)     /* non-zero to print w_sum in brackets */
#define w_ramsize   W32(20)     /* detected main RAM bytes */
#define w_faddr     W32(24)     /* address of the first bad longword */
#define w_fexp      W32(28)     /* what should have been there */
#define w_fgot      W32(32)     /* what was actually read */
#define w_sum       W32(36)     /* checksum to print in brackets */
#define w_buf       (WORK + 40) /* string scratch, 12 bytes, built backwards */
#define w_buf_end   (w_buf + 12)
#define w_jbp       W32(56)     /* active jmp_buf, 0 = no guard armed.  Must
                                   clear w_buf_end at WORK+52, which holds the
                                   scratch string terminator. */
/* WORK+60 .. WORK+255 spare */

#endif
