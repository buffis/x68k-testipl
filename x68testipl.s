;-----------------------------------------------------------------------------
; x68testipl.s -- TEST-IPL, a power-on self test for the Sharp X68000 family
;
; Assembles with vasm (Motorola syntax) to a raw binary that build.py pads into
; a 128K IPL ROM image.  Takes the machine at reset, runs the tests, reports on
; screen and over RS-232C, and stops.  Contains no Sharp code.
;
; Constraints this code works under:
;   * It runs at reset, so nothing is initialised: no stack, no vector table,
;     no video, no RAM.  Main RAM is under test, so the stack must not live
;     there -- off-screen text VRAM is used instead.
;   * Absolute, position-dependent code.  TESTIPL_BASE must match build.py.
;   * Nothing runs after us, so the tests are free to leave hardware dirty.
;
; docs/TESTS.md covers every report line in detail: what is read or written at
; which address, what a pass proves, and what it does not.
;-----------------------------------------------------------------------------

; Where the code sits in the ROM.  Normally supplied by build.py with
; -DTESTIPL_BASE=...; the default matches it.  The 68000 fetches SSP from
; $FF0000 and its reset PC from $FF0004, so the code starts just past those two
; longwords.  TESTIPL_BASE must be 4-aligned: the ROM checksum loop skips its
; own reference longword by address compare, which needs a longword boundary.
                ifnd    TESTIPL_BASE
TESTIPL_BASE    equ     $FF0010
                endif

;--- hardware ----------------------------------------------------------------
; Graphic VRAM is 512K of physical memory presented in a 2MB window; how the
; window folds onto it depends on CRTC R20, so the test sets R20 explicitly.
GVRAM           equ     $C00000
GVRAM_TEST_END  equ     $C80000         ; all 512K of it
TVRAM           equ     $E00000         ; 4 planes, 128K each, contiguous
; Top 4K of plane 3 = text lines 992-1023, off the bottom of a 512-line screen.
; The stack and work area live there, so it is held back from the TVRAM test.
TVRAM_RESV      equ     $E7F000
TVRAM_PLANE     equ     $20000          ; bytes between planes
CRTC            equ     $E80000
TPAL            equ     $E82200
VC_R0           equ     $E82400
VC_R1           equ     $E82500
VC_R2           equ     $E82600
DMAC            equ     $E84000
MFP             equ     $E88000         ; register n at MFP+1+2n
RTC             equ     $E8A000         ; register n at RTC+1+2n
RTC_MODE        equ     RTC+1+13*2      ; mode register, 4 bits wide:
RTC_BANK        equ     $01             ;   bit 0 register bank
RTC_ALARM_EN    equ     $04             ;   bit 2 alarm enable
RTC_TIMER_EN    equ     $08             ;   bit 3 timer enable -- the clock only
                                        ;   advances while this is set
AREASET         equ     $E86001         ; supervisor area set, byte on the odd lane
SYSPORT         equ     $E8E000
OPM             equ     $E90000
FDC             equ     $E94000
SCSI            equ     $E96020         ; register n at SCSI+1+2n
SCC             equ     $E98000
PPI             equ     $E9A000
SPRRAM          equ     $EB8000
SPRRAM_END      equ     $EC0000
SPRREG          equ     $EB0808         ; BG / sprite control register
SPR_HTOTAL      equ     $EB080A
SPR_HDISP       equ     $EB080C
SPR_VDISP       equ     $EB080E
SPR_RES         equ     $EB0810
SRAM            equ     $ED0000
CGROM           equ     $F00000
CGROM_LEN       equ     $C0000
; Confirmed on a real PRO and identical in every dump in circulation.
CGROM_SUM       equ     $13C64BFE
ANK8X16         equ     $F3A800         ; 8x16 half-width font, 16 bytes/char
IPLROM          equ     $FE0000
IPLROM_LEN      equ     $20000

SCC_ACTL        equ     SCC+5           ; channel A = RS-232C
SCC_ADATA       equ     SCC+7
MFP_GPIP        equ     MFP+1           ; register 0: video timing inputs
GPIP_VDISP      equ     $10             ; bit 4, driven by the CRTC
GPIP_HSYNC      equ     $80             ; bit 7, driven by the CRTC
GPIP_VID        equ     GPIP_VDISP|GPIP_HSYNC

MAX_RAM_MB      equ     12              ; X68000 address space tops out here

;--- screen ------------------------------------------------------------------
SCR_ROWS        equ     32              ; 512 / 16
TV_STRIDE       equ     128             ; bytes per scanline in a text plane
COL_NORMAL      equ     1               ; plane 0        -> white
COL_GOOD        equ     2               ; plane 1        -> green
COL_BAD         equ     3               ; plane 0 and 1  -> red
RESULT_COL      equ     30              ; column every verdict lands on
; Every line starts one column in.  A real X68000 monitor overscans, and the
; leftmost column is the one that gets cut off on a badly adjusted set.
LEFT_MARGIN     equ     1

;--- stack and work area, in the reserved top 4K of text VRAM -----------------
; Both start at the same address: the stack grows down from it, the work area
; grows up.  Main RAM is under test and graphic VRAM folds onto itself, so text
; VRAM is the only memory here that is flat and not a test subject.
STACK_TOP       equ     $E7FF00         ; grows down through $E7F000-$E7FEFF
; w_col and w_row must stay at WORK+0 and WORK+2: the MAME harness scripts read
; the cursor straight out of $E7FF00/$E7FF02 to tell when a run has finished.
WORK            equ     $E7FF00         ; grows up through $E7FF00-$E7FF33
w_col           equ     WORK+0          ; word  cursor column
w_row           equ     WORK+2          ; word  cursor row
w_fail          equ     WORK+4          ; word  failure count
w_tvram         equ     WORK+6          ; word  TVRAM verdict, tested pre-video
w_serial        equ     WORK+8          ; word  non-zero once serial is given up on
w_fverdict      equ     WORK+10         ; word  verdict to use if a test faults
w_progcol       equ     WORK+12         ; word  column a run of progress marks
                                        ;       began at, $FFFF when none is open
w_addrcol       equ     WORK+14         ; word  column test_dram's address field
                                        ;       sits at, $FFFF when none is open
; Detail for the line under a FAIL.  run_test clears w_fdetail before every
; test, so a test that sets it owns the line and nothing stale survives.
w_fdetail       equ     WORK+16         ; word  kind: 0 none, 1 exp/got, 2 stuck
; A checksum to show in brackets after the verdict, e.g. OK (13C64BFE).  Also
; cleared by run_test, so only the test that sets it owns the brackets.
w_sumshow       equ     WORK+18         ; word  non-zero to print w_sum
w_ramsize       equ     WORK+20         ; long  detected main RAM bytes
w_faddr         equ     WORK+24         ; long  address of the first bad longword
w_fexp          equ     WORK+28         ; long  what should have been there
w_fgot          equ     WORK+32         ; long  what was actually read
w_sum           equ     WORK+36         ; long  checksum to print in brackets
w_buf           equ     WORK+40         ; string scratch, built backwards from
w_buf_end       equ     w_buf+12        ;   the end: 11 digits plus a terminator

MEM_XOR         equ     $5A5AA5A5       ; address-derived fill pattern

;-----------------------------------------------------------------------------
; probe_stack \1 -- if off-screen text VRAM stores data, point a7 at it;
; otherwise branch to \1 with a7 untouched.
;
; A macro rather than a subroutine because the first use runs before there is a
; stack to bsr with.  Two patterns and a longword below the base, so a window
; that folds onto itself or does not decode at all cannot pass.
;-----------------------------------------------------------------------------
probe_stack     macro
                lea     TVRAM_RESV,a0
                move.l  #$5A5AA5A5,d0
                move.l  #$0F0FF0F0,d1
                move.l  d0,(a0)
                move.l  d1,4(a0)
                move.l  d0,-8(a0)
                cmp.l   (a0),d0
                bne.s   \1
                cmp.l   4(a0),d1
                bne.s   \1
                cmp.l   -8(a0),d0
                bne.s   \1
                lea     STACK_TOP,a7
                endm

                org     TESTIPL_BASE

;=============================================================================
; header -- fixed layout so build.py can patch the checksum without reading
; symbols out of the assembler listing.
;   +0  branch to the entry point (the reset vector points here)
;   +4  expected ROM checksum
;=============================================================================
                bra.w   testipl_entry
romsum_ref:     dc.l    0

;=============================================================================
; entry
;=============================================================================
testipl_entry:
                move.w  #$2700,sr               ; supervisor, interrupts off
                reset                           ; reset external devices

;--- let low memory be written -----------------------------------------------
; AREASET governs what may be written to low memory and comes up undefined at
; power-on; leave it alone and writes above $400 hang the bus on real hardware.
; A stock IPL clears it within a few instructions of reset.  MAME does not
; implement the register, so this cannot be verified in emulation.
                move.b  #0,AREASET

;--- make video RAM decode predictable before anything touches it ------------
; Text VRAM is only a flat array while CRTC R21 has simultaneous-plane access
; and the access mask switched off, and R21 is undefined at power-on.  These
; two stores have no dependencies, so they are safe to do with no stack.
                move.w  #$0B16,CRTC+$28         ; R20 memory / display mode
                clr.w   CRTC+$2A                ; R21 plain, unmasked writes

;--- find somewhere to put a stack -------------------------------------------
                probe_stack .no_tvram
                bra.s   .have_stack
.no_tvram:
; Text VRAM is unusable.  Fall back to low RAM; if that is dead too there is
; nothing left to report with.
                lea     $2000,a0
                move.l  #$5A5AA5A5,d0
                move.l  d0,-4(a0)
                cmp.l   -4(a0),d0
                bne     dead_end
                lea     $2000,a7
.have_stack:
; Fill ALL 256 exception vectors before touching hardware, not just the two we
; use.  Level 7 is non-maskable, so the move.w #$2700,sr above is no protection:
; any interrupt raised from the undefined power-on state would vector through
; whatever noise low RAM holds.  Both stock IPLs do this as their first act.
                lea     $0,a0
                move.l  #vec_ignore,d0
                move.w  #255,d1
.fillvec:
                move.l  d0,(a0)+
                dbra    d1,.fillvec

                move.l  #fault_handler,$008.w   ; bus error
                move.l  #fault_handler,$00C.w   ; address error
                move.l  #nmi_handler,$07C.w     ; level 7 -- see below

;--- stop the DMAC before anything reads or writes memory in bulk ------------
; The HD63450 comes up undefined, and a channel that powers up armed will
; arbitrate for the bus and run transfers of its own.  Abort every channel, idle
; it, clear its status.  Guarded: this is the first device touched, so a fault
; here must not jump through a stale a3.
                lea     .dmac_done,a3
                move.l  a7,a4
                lea     DMAC,a0
                moveq   #3,d1
.dmac_chan:
                move.b  #$10,7(a0)              ; CCR: software abort
                nop
                clr.b   7(a0)                   ; CCR: idle
                move.b  #$FF,0(a0)              ; CSR: clear status
                lea     $40(a0),a0
                dbra    d1,.dmac_chan
.dmac_done:

;--- video first, then anything that has to be remembered --------------------
; Text VRAM is refreshed by the display, so its cells decay while the CRTC is
; idle.  Bring the display up and wait for it to actually scan before testing
; half a megabyte of it.  (The stack probe above is safe either way: it writes
; and reads back within microseconds.)
                bsr     video_init              ; CRTC + video controller + palette
                bsr     wait_scanning

;--- get the stack out of main RAM ------------------------------------------
; The probe at entry ran before the CRTC was programmed, so on a cold machine it
; takes the fallback and leaves the stack at $2000 -- inside the region test_dram
; patterns over.  Now that the display is scanning, ask again.  Straight-line
; code with nothing live on the stack, so a7 can simply be reloaded.
                probe_stack .keep_stack
.keep_stack:

; The work area lives in text VRAM, so it is only held up once the display is
; scanning.  Initialise it here, after video_init -- not before, where it would
; have to survive the whole of test_tvram unrefreshed.
                clr.w   w_fail
                clr.l   w_ramsize
                move.w  #LEFT_MARGIN,w_col
                clr.w   w_row
                move.w  #$FFFF,w_addrcol
                move.w  #$FFFF,w_progcol
                clr.w   w_sumshow
                clr.w   w_fdetail               ; the Text VRAM line bypasses
                                                ; run_test, so nothing else
                                                ; would clear it

                bsr     serial_init
                lea     s_banner,a0
                bsr     serial_str
                bsr     serial_crlf

                bsr     test_tvram
                move.w  d0,w_tvram

                bsr     tvram_clear

                lea     s_banner,a0
                moveq   #COL_NORMAL,d1
                bsr     print_str
                bsr     newline
                bsr     newline

;=============================================================================
; the tests
;=============================================================================
; Devices first, then memory.  Memory is second on purpose: main RAM is the
; slowest test and the one most likely to hang a sick machine, so by the time
; it runs the whole report above it is already on screen.

;--- devices -----------------------------------------------------------------
                lea     n_mfp,a0
                lea     test_mfp,a1
                bsr     run_test

                lea     n_vidtim,a0
                lea     test_vidtiming,a1
                bsr     run_test

                lea     n_rtc,a0
                lea     test_rtc,a1
                bsr     run_test

                lea     n_rtcosc,a0
                lea     test_rtcosc,a1
                bsr     run_test

                lea     n_dmac,a0
                lea     test_dmac,a1
                bsr     run_test

                lea     n_opm,a0
                lea     test_opm,a1
                bsr     run_test

                lea     n_ppi,a0
                lea     test_ppi,a1
                bsr     run_test

                lea     n_fdc,a0
                lea     test_fdc,a1
                bsr     run_test

                lea     n_scsi,a0
                lea     test_scsi,a1
                bsr     run_test_opt

;--- memory ------------------------------------------------------------------
                lea     n_romsum,a0
                lea     test_romsum,a1
                bsr     run_test

                lea     n_cgrom,a0
                lea     test_cgrom,a1
                bsr     run_test

; Verdict was worked out at startup, before anything could be printed; reported
; here with the rest of memory.
                lea     n_tvram,a0
                bsr     line_start
                move.w  w_tvram,d0
                and.l   #$FFFF,d0
                bsr     verdict

                lea     n_gvram,a0
                lea     test_gvram,a1
                bsr     run_test

; Optional: sprite RAM does not answer the bus in every screen mode, so a fault
; here reads SKIP.  RAM that answers with the wrong pattern still FAILs.
                lea     n_sprram,a0
                lea     test_sprram,a1
                bsr     run_test_opt
                move.w  #$0B16,CRTC+$28         ; back to the report's mode,
                nop                             ; whether the test faulted or not

                lea     n_sram,a0
                lea     test_sram,a1
                bsr     run_test

; Size first, on its own line, so the machine's memory is on screen before the
; slow part starts; then the pattern test under it; then the cross-check that
; what was found matches what SRAM says should be there.
                lea     n_ramsize,a0
                lea     test_ramsize,a1
                bsr     run_test

                lea     n_dram,a0
                lea     test_dram,a1
                bsr     run_test

                lea     n_ramchk,a0
                lea     test_ramsize_sram,a1
                bsr     run_test

;=============================================================================
; summary, then stop
;=============================================================================
                bsr     newline
                move.w  w_fail,d0
                bne.s   .failures
                lea     s_allok,a0
                moveq   #COL_GOOD,d1
                bsr     print_str
                lea     s_allok,a0
                bsr     serial_str
                bsr     serial_crlf
                bra.s   .halt
.failures:
                and.l   #$FFFF,d0
                moveq   #COL_BAD,d1
                bsr     print_dec
                lea     s_failed,a0
                moveq   #COL_BAD,d1
                bsr     print_str
                lea     s_failed,a0
                bsr     serial_str
                bsr     serial_crlf
.halt:
                ifd     IPL_ENTRY
; Hold long enough for the report to be read, then hand the machine over: the
; IPL clears the screen on its way to booting, so without a pause the whole run
; would flash past.  A failing run holds longer, since that is the one you
; actually want to read.  The serial log has it all either way.
                moveq   #3,d0
                tst.w   w_fail
                beq.s   .hold
                moveq   #10,d0
.hold:
                bsr     delay_seconds
                lea     s_booting,a0
                bsr     serial_str
                bsr     serial_crlf
                bsr     serial_drain            ; or the IPL's SCC reset eats it
                move.w  #$2700,sr
                jmp     IPL_ENTRY               ; the injected IPL takes over
                endif
                ifnd    IPL_ENTRY
; Standalone there is nothing to hand over to, so stop with the report up.
; Interrupts are already masked, so STOP parks here for good; the loop is belt
; and braces against a stray NMI.
                bsr     newline
                lea     s_halted,a0
                moveq   #COL_NORMAL,d1
                bsr     print_str
                lea     s_halted,a0
                bsr     serial_str
                bsr     serial_crlf
.stopped:
                stop    #$2700
                bra.s   .stopped
                endif

; nmi_handler: level 7, which no status register can mask.
;
; A plain rte is not enough.  If something has latched an NMI -- and from cold
; the hardware is in whatever state power-up left it -- an rte returns straight
; into it again and the machine spins in an interrupt loop that looks exactly
; like a stalled bus.  Writing $0C to the system port is what acknowledges it,
; which is what exbios' handler does first too.
nmi_handler:
                move.b  #$0C,SYSPORT+7
                rte

; vec_ignore: anything we have not given a real handler to.  Returning is right
; for a spurious interrupt; for a genuine fault it is no worse than the garbage
; address it replaces.
vec_ignore:
                rte

dead_end:
; No usable memory anywhere: nothing can be reported.  Make the failure at
; least visible on a scope by rattling the system port.
                move.b  #$0F,SYSPORT+1
                move.b  #$00,SYSPORT+1
                bra.s   dead_end

; Bus / address error handler.  A group 0 fault cannot be resumed, so the only
; recovery is to discard the frame and jump somewhere known-good; a3 and a4 are
; set up by whichever probe is running.
fault_handler:
                movea.l a4,a7
                jmp     (a3)

;=============================================================================
; generic memory fill / verify
;   in:  a0 = base, d1 = longword count (32 bit)
;   out: d0 = 0 pass / 1 fail, a0 = end (fill) or failing address (verify)
; The pattern is derived from the address, so stuck or swapped address lines
; show up as well as stuck data bits.  Both loop in chunks of $8000 longwords
; because dbra counts 16 bits and the regions are bigger than that.
;=============================================================================
mem_fill:
                movem.l d1-d3,-(sp)
                move.l  #MEM_XOR,d3
.chunk:
                move.l  d1,d2
                cmp.l   #$8000,d2
                bls.s   .small
                move.l  #$8000,d2
.small:
                sub.l   d2,d1
                subq.w  #1,d2
.loop:
                move.l  a0,d0
                eor.l   d3,d0
                move.l  d0,(a0)+
                dbra    d2,.loop
                tst.l   d1
                bne.s   .chunk
                moveq   #0,d0
                movem.l (sp)+,d1-d3
                rts

mem_verify:
                movem.l d1-d3,-(sp)
                move.l  #MEM_XOR,d3
.chunk:
                move.l  d1,d2
                cmp.l   #$8000,d2
                bls.s   .small
                move.l  #$8000,d2
.small:
                sub.l   d2,d1
                subq.w  #1,d2
.loop:
                move.l  a0,d0
                eor.l   d3,d0
                cmp.l   (a0)+,d0
                bne.s   .bad
                dbra    d2,.loop
                tst.l   d1
                bne.s   .chunk
                moveq   #0,d0
                bra.s   .out
.bad:
                subq.l  #4,a0                   ; point at the failing longword
; Which address failed, and how, is the difference between "some RAM is bad"
; and knowing which device to replace: the bits that differ name the chip.
                move.l  a0,w_faddr
                move.l  d0,w_fexp
                move.l  (a0),w_fgot
                move.w  #1,w_fdetail
                moveq   #1,d0
.out:
                movem.l (sp)+,d1-d3
                rts

;=============================================================================
; test bodies -- each returns d0 = 0 pass, 2 skip, 6 "size line", else fail
;=============================================================================

;--- text VRAM ---------------------------------------------------------------
; Runs before video init, so all four planes are free to use.
test_tvram:
                movem.l d1/a0,-(sp)
                lea     TVRAM,a0
                move.l  #(TVRAM_RESV-TVRAM)/4,d1
                bsr     mem_fill
                lea     TVRAM,a0
                move.l  #(TVRAM_RESV-TVRAM)/4,d1
                bsr     mem_verify
                movem.l (sp)+,d1/a0
                rts

;--- CGROM checksum ----------------------------------------------------------
; Sums the whole 768K font ROM and compares against CGROM_SUM.  The value is
; printed in brackets whichever way the verdict goes, so a machine carrying a
; different revision gives you a number to record rather than a bare FAIL.
test_cgrom:
                movem.l d1-d2/a0,-(sp)
                lea     CGROM,a0
                moveq   #CGROM_LEN/$40000-1,d2  ; $40000 bytes per inner pass
                moveq   #0,d0
.chunk:
                move.w  #$FFFF,d1
.loop:          add.l   (a0)+,d0
                dbra    d1,.loop
                dbra    d2,.chunk
                move.l  d0,w_sum
                move.w  #1,w_sumshow
                cmp.l   #CGROM_SUM,d0
                bne.s   .bad
                moveq   #0,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1-d2/a0
                rts

;--- IPL ROM checksum --------------------------------------------------------
; Sums the whole 128K ROM except the four bytes holding the reference value, so
; the ROM verifies the very code you are running.  This checks the EPROM burn,
; not the machine -- the machine's own IPL is out of its socket while this one
; is in it.
test_romsum:
                movem.l d1/a0-a1,-(sp)
                lea     IPLROM,a0
                lea     romsum_ref,a1
                move.w  #IPLROM_LEN/4-1,d1
                moveq   #0,d0
.loop:
                cmpa.l  a0,a1
                beq.s   .skip
                add.l   (a0)+,d0
                dbra    d1,.loop
                bra.s   .done
.skip:
                addq.l  #4,a0
                dbra    d1,.loop
.done:
                move.l  d0,w_sum                ; shown in brackets either way
                move.w  #1,w_sumshow
                sub.l   romsum_ref,d0
                movem.l (sp)+,d1/a0-a1
                rts

;--- graphic VRAM ------------------------------------------------------------
; The 2MB graphic VRAM window folds onto 512K of real memory, and how it folds
; is set by CRTC R20 bits 8-11.  Switch to the mode that maps the first 512K
; through as plain 16-bit words, test all of it, then put R20 back for the
; display.
test_gvram:
                movem.l d1/a0,-(sp)
                move.w  #$0316,CRTC+$28         ; whole words, no nibble packing
                lea     GVRAM,a0
                move.l  #(GVRAM_TEST_END-GVRAM)/4,d1
                bsr     mem_fill
                lea     GVRAM,a0
                move.l  #(GVRAM_TEST_END-GVRAM)/4,d1
                bsr     mem_verify
                move.w  #$0B16,CRTC+$28         ; back to the display mode
                movem.l (sp)+,d1/a0
                rts

;--- main RAM: sizing ---------------------------------------------------------
; Sizes memory by tagging each megabyte and reading every tag back, which
; catches both bus errors off the top and aliasing on a part-populated machine.
; The result goes in w_ramsize and is reported as this line's verdict, so the
; size is on screen before the pattern pass below it starts running.
test_ramsize:
                movem.l d1-d6/a0-a4,-(sp)

; The first kilobyte must work before exception vectors can be installed.  a3
; and a4 still belong to run_test here, so a fault lands on its FAIL path.
                lea     $0,a0
                move.l  #$C3C35A5A,d0
                move.l  d0,(a0)
                move.l  d0,$3FC(a0)
                cmp.l   (a0),d0
                bne     .dead_low
                cmp.l   $3FC(a0),d0
                bne     .dead_low

                move.l  a7,a4                   ; stack the handler restores

;--- phase 1a: tag each megabyte --------------------------------------------
                lea     .sized,a3               ; a bus error here just means
                moveq   #0,d3                   ; we have run off the top
.probe:
                move.l  d3,d0
                swap    d0
                lsl.l   #4,d0                   ; d0 = d3 * $100000
                movea.l d0,a0
                move.l  d3,d1
                add.l   #$D0000000,d1
                move.l  d1,(a0)
                nop
                cmp.l   (a0),d1
                bne.s   .sized
                bsr     dram_tick               ; serial only: where a hang was
                addq.l  #1,d3
                cmp.l   #MAX_RAM_MB,d3
                blt.s   .probe
.sized:
                move.l  d3,d4
                tst.l   d4
                beq     .dead_low

;--- phase 1b: read every tag back, which is what catches aliasing -----------
                lea     .verified,a3
                moveq   #0,d3
.verify:
                move.l  d3,d0
                swap    d0
                lsl.l   #4,d0
                movea.l d0,a0
                move.l  d3,d1
                add.l   #$D0000000,d1
                cmp.l   (a0),d1
                bne.s   .verified
                addq.l  #1,d3
                cmp.l   d4,d3
                blt.s   .verify
.verified:
                move.l  d3,d4
                tst.l   d4
                beq     .dead_low
                move.l  d4,d0
                swap    d0
                lsl.l   #4,d0
                move.l  d0,w_ramsize

;--- phase 1c: is the megabyte above the top absent, or present and faulty? --
; Sizing stops at the first megabyte whose tag does not read back, which happens
; both when there is no memory there and when there is memory with a stuck bit.
; Left alone, a failing chip would quietly be reported as a smaller machine.
; Memory that is present still stores most of what you write, so write all-zeroes
; and all-ones and count how many bits misbehave: a handful means a faulty
; device, everything means there is nothing there at all.
                cmp.l   #MAX_RAM_MB,d4
                bge.s   .no_boundary
                lea     .no_boundary,a3         ; a fault here just means absent
                move.l  d4,d0
                swap    d0
                lsl.l   #4,d0
                movea.l d0,a0
                moveq   #0,d5
                move.l  d5,(a0)
                nop
                move.l  (a0),d5                 ; bits that would not go low
                moveq   #-1,d6
                move.l  d6,(a0)
                nop
                move.l  (a0),d6
                not.l   d6                      ; bits that would not go high
                or.l    d6,d5                   ; every bit that misbehaved
                beq.s   .no_boundary
                move.l  d5,d0
                bsr     count_bits
                cmp.l   #8,d0
                bhi.s   .no_boundary            ; too many: nothing is there
; A few bits misbehaving is a faulty device, and the mask says which ones --
; the bit numbers map straight onto the chips in that bank.
                move.l  a0,w_faddr
                move.l  d5,w_fgot
                move.w  #2,w_fdetail
                moveq   #3,d0                   ; a few: the device is faulty
                bra     .out
.no_boundary:
                moveq   #6,d0                   ; verdict prints w_ramsize
                bra.s   .out
.dead_low:
; Not 2: verdict reads 2 as SKIP, and no memory at all is emphatically a FAIL.
                clr.l   w_ramsize
                moveq   #4,d0
.out:
                movem.l (sp)+,d1-d6/a0-a4
                rts

;--- main RAM: pattern test ---------------------------------------------------
; Everything above the vector table, filled then verified a megabyte at a time.
; Runs after test_ramsize, which is where w_ramsize comes from.
test_dram:
                movem.l d1-d6/a0-a4,-(sp)
                move.l  a7,a4                   ; stack the handler restores
                move.l  w_ramsize,d6
                beq     .nosize                 ; sizing failed; nothing to test
; Never pattern over our own stack.  If a7 is still in main RAM then both stack
; probes failed, and patterning would overwrite the return addresses under it.
                cmp.l   #TVRAM,a7
                bcc.s   .stack_is_safe
                moveq   #2,d0                   ; SKIP rather than self-destruct
                bra     .out
.stack_is_safe:
                lea     .bad,a3
; Everything is filled before anything is verified, so aliasing between
; megabytes still shows up -- the slicing only exists to punctuate it.
                lea     $400,a0
                bsr     .pwords
.pfill:
                moveq   #'W',d0                 ; writing
                bsr     .pmark                  ; the block about to be filled
                bsr     .pslice
                bsr     mem_fill
                tst.l   d6
                bne.s   .pfill

                lea     $400,a0
                bsr     .pwords
.pver:
                moveq   #'V',d0
                bsr     .pmark
                bsr     .pslice
                bsr     mem_verify
                tst.l   d0
                bne     .bad
                tst.l   d6
                bne.s   .pver
                moveq   #0,d0
                bra     .out

; .pwords: d6 = longwords from $400 to the top of memory.
.pwords:
                move.l  w_ramsize,d6
                sub.l   #$400,d6
                lsr.l   #2,d6
                rts

; .pslice: take up to 2048 longwords (8K) off d6 and return it in d1.
;
; The slice size only sets how precisely the on-screen address names a stall.
; It is not a hardware workaround, and smaller slices cost real time: 512 adds
; about twelve seconds at 12 MB.
.pslice:
                move.l  d6,d1
                cmp.l   #2048,d1
                bls.s   .pslice_all
                move.l  #2048,d1
.pslice_all:
                sub.l   d1,d6
                rts

; .pmark: d0 = phase letter ('W' filling, 'V' verifying), a0 = the address about
; to be worked on.
;
; Shown as a letter and an address overwritten in place, because 80 slices per
; 10 MB would run off the end of the line as marks but a number always fits --
; and it says exactly which 8K block a stall happened in, which is the whole
; point.  Written before the slice, not after, so the address on screen is the
; one being worked on when it stops.  The serial line gets a plain dot per
; slice; it has no cursor to rewind.
.pmark:
                movem.l d0-d2/a0,-(sp)
                move.l  d0,d2                   ; phase letter
                moveq   #'.',d0
                bsr     serial_char
                cmp.w   #$FFFF,w_addrcol
                bne.s   .pmark_have
                move.w  w_col,w_addrcol
; Claim the progress column too.  This field is the only thing test_dram prints,
; so if w_progcol stayed $FFFF progress_clear would do nothing and the verdict
; would land after the address rather than over it.
                move.w  w_col,w_progcol
.pmark_have:
                move.w  w_addrcol,w_col         ; back to the start of the field
                move.l  d2,d0
                moveq   #COL_NORMAL,d1
                bsr     putchar
                moveq   #'$',d0
                moveq   #COL_NORMAL,d1
                bsr     putchar
                move.l  a0,d0
                moveq   #8,d2
                bsr     print_hex_scr
                movem.l (sp)+,d0-d2/a0
                rts
.bad:
                moveq   #1,d0
                bra.s   .out
.nosize:
                moveq   #2,d0                   ; SKIP: test_ramsize already
                                                ; failed and said why
.out:
                movem.l (sp)+,d1-d6/a0-a4
                rts

; dram_tick: one dot per megabyte sized, so a machine that stalls part way
; through says where rather than just sitting on an unfinished line.
dram_tick:
                movem.l d0,-(sp)
                moveq   #'.',d0
                bsr     progress_char
                movem.l (sp)+,d0
                rts

; progress_char: d0 = character, to screen and serial.  Remembers the column the
; run started at so the marks can be wiped before the verdict is printed -- they
; would otherwise push it out of its column and the whole report would stop
; lining up.
progress_char:
                movem.l d0-d1,-(sp)
                cmp.w   #$FFFF,w_progcol
                bne.s   .have
                move.w  w_col,w_progcol
.have:
                moveq   #COL_NORMAL,d1
                bsr     putchar
                bsr     serial_char
                movem.l (sp)+,d0-d1
                rts

; progress_clear: wipe the marks and put the cursor back where they started.
; The serial log keeps them -- there is no cursor to rewind there, and a log
; showing how far a run got is the entire point of them.
progress_clear:
                movem.l d0-d2,-(sp)
                move.w  w_progcol,d2
                cmp.w   #$FFFF,d2
                beq.s   .out
                move.w  w_col,d0
                sub.w   d2,d0                   ; how many marks were printed
                move.w  d2,w_col
                subq.w  #1,d0
                bmi.s   .done
.blank:
                movem.l d0,-(sp)
                moveq   #' ',d0
                moveq   #COL_NORMAL,d1
                bsr     putchar
                movem.l (sp)+,d0
                dbra    d0,.blank
.done:
                move.w  d2,w_col
                move.w  #$FFFF,w_progcol
.out:
                movem.l (sp)+,d0-d2
                rts

; count_bits: d0 = value in, population count out.
count_bits:
                movem.l d1-d2,-(sp)
                move.l  d0,d1
                moveq   #0,d0
                moveq   #31,d2
.loop:
                lsr.l   #1,d1
                bcc.s   .zero
                addq.l  #1,d0
.zero:
                dbra    d2,.loop
                movem.l (sp)+,d1-d2
                rts

;--- main RAM vs SRAM --------------------------------------------------------
; Human68k records the memory size it last configured at $ED0008.  Comparing it
; with what we just measured catches a whole bank having gone missing.  The
; stock IPL rewrites the value on every boot, so the mismatch only shows on the
; first boot after the fault appears.  Returns SKIP when SRAM holds nothing
; plausible, so an unconfigured machine is not reported as broken.
;
; (Under MAME that address is faked from the configured RAM size rather than
; read from NVRAM, so there it compares against the emulated machine's size.)
test_ramsize_sram:
                movem.l d1,-(sp)
                move.l  SRAM+8,d1
                beq.s   .skip
                cmp.l   #$C00000,d1             ; more than 12MB is not credible
                bhi.s   .skip
                move.l  d1,d0
                and.l   #$000FFFFF,d0           ; must be a whole megabyte
                bne.s   .skip
                cmp.l   w_ramsize,d1
                bne.s   .bad
                moveq   #0,d0
                bra.s   .out
.skip:          moveq   #2,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1
                rts

;--- battery SRAM ------------------------------------------------------------
; Read-only: SRAM holds the user's settings, so check the Human68k signature
; rather than writing to it.  A failure here normally means the backup battery
; is flat and the contents have been lost, not that the chip is bad -- the stock
; IPL re-initialises SRAM when it sees the same thing.
test_sram:
                movem.l d1/a0-a1,-(sp)
                lea     SRAM,a0
                lea     s_sramsig,a1
                moveq   #7,d1
.loop:
                cmpm.b  (a0)+,(a1)+
                bne.s   .bad
                dbra    d1,.loop
                moveq   #0,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1/a0-a1
                rts

;--- MC68901 MFP -------------------------------------------------------------
; Timer B is stopped, so its data register behaves as a scratch register.  Two
; complementary patterns, so a bus line stuck either way cannot pass.
test_mfp:
                movem.l d1/a0,-(sp)
                lea     MFP,a0
                clr.b   1+13*2(a0)              ; TBCR = 0, stop timer B
                move.b  #$A5,1+16*2(a0)         ; TBDR
                nop
                move.b  1+16*2(a0),d1
                cmp.b   #$A5,d1
                bne.s   .bad
                move.b  #$5A,1+16*2(a0)
                nop
                move.b  1+16*2(a0),d1
                cmp.b   #$5A,d1
                bne.s   .bad
                clr.b   1+16*2(a0)
                moveq   #0,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1/a0
                rts

;--- CRTC liveness, via the MFP GPIP video timing inputs ---------------------
; The CRTC register file is write-only on real silicon -- R00/R04 read back
; $0000 while the screen is plainly being scanned -- so no readback test of it
; can work.  Ask the MFP instead: the CRTC drives V-DISP into GPIP bit 4 and
; H-SYNC into bit 7, so either one toggling is externally visible proof that it
; is generating timing.
;
; Sample the port hard, accumulating OR and AND; OR & ~AND is the set of bits
; that changed.  An undriven bus reads all-ones constantly, so it cancels out
; and correctly reads as dead rather than as live data.
;
; GPIP bit 6 (raster interrupt) is deliberately out of the mask: it only toggles
; once a raster line has been programmed.  For the same reason one of the two
; signals is enough.
;
; Exits as soon as both bits move, about one frame; the counter only bounds the
; dead case.  V-DISP toggles once per ~18 ms, so the window must be able to span
; a frame: 40000 iterations is ~200 ms at 10 MHz, ~60 ms on a 25 MHz 68030.
test_vidtiming:
                movem.l d1-d4/a0,-(sp)
                lea     MFP_GPIP,a0
                moveq   #0,d1                   ; OR accumulator
                moveq   #-1,d2                  ; AND accumulator
                moveq   #0,d4                   ; bits seen moving, masked
                move.l  #40000,d3
.loop:
                moveq   #0,d0
                move.b  (a0),d0
                or.l    d0,d1
                and.l   d0,d2
                move.l  d2,d4
                not.l   d4
                and.l   d1,d4                   ; OR & ~AND = bits that moved
                and.l   #GPIP_VID,d4
                cmp.l   #GPIP_VID,d4
                beq.s   .live                   ; both signals seen, stop early
                subq.l  #1,d3
                bne.s   .loop
                tst.l   d4                      ; window expired: either one?
                bne.s   .live
                moveq   #1,d0
                bra.s   .out
.live:
                moveq   #0,d0
.out:
                movem.l (sp)+,d1-d4/a0
                rts

;--- RP5C15 RTC: is the chip there and does its bus work? --------------------
; Bank 1 holds the alarm registers, which are plain storage and do not depend on
; the oscillator at all.  Select bank 1, write $5 then $A to alarm register 2
; and read each back.  Proves the register file and the bus to the chip and
; nothing else -- whether the clock runs is test_rtcosc's problem.
;
; Deliberately not a BCD sanity check on the time registers: a clock frozen at a
; plausible time would pass that.
test_rtc:
                movem.l d1-d2,-(sp)
                move.b  RTC_MODE,d1
                and.b   #RTC_ALARM_EN|RTC_TIMER_EN,d1
                or.b    #RTC_BANK,d1            ; bank 1, leave the rest alone
                move.b  d1,RTC_MODE
                nop
                move.b  #$05,RTC+1+2*2
                nop
                move.b  RTC+1+2*2,d1
                and.b   #$0F,d1
                move.b  #$0A,RTC+1+2*2
                nop
                move.b  RTC+1+2*2,d2
                and.b   #$0F,d2
; Back to bank 0 before judging, so the chip is left the way it was found.
                move.b  RTC_MODE,d0
                and.b   #RTC_ALARM_EN|RTC_TIMER_EN,d0
                move.b  d0,RTC_MODE
                nop
                cmp.b   #$05,d1
                bne.s   .bad
                cmp.b   #$0A,d2
                bne.s   .bad
                moveq   #0,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1-d2
                rts

;--- RP5C15 oscillator: does the clock actually advance? ---------------------
; A dead 32.768 kHz crystal, or battery corrosion around it, is the classic
; X68000 failure and nothing above would notice: the registers keep whatever
; they were left holding.  Read the seconds, wait, read again.
;
; Timer-enable is set first -- a clock merely switched off is a different fault
; from a dead oscillator, and MAME comes up with the bit clear.
;
; Timed by counting V-DISP frames, not delay_seconds: that is calibrated for a
; 10 MHz 68000 and runs several times faster on an X68030.  Frames are ~55 Hz
; whatever the CPU does, so counting them measures real time.  With no CRTC
; scanning there are no frames and it falls back to delay_seconds -- such a
; machine has already failed the video timing test a line earlier.
test_rtcosc:
                movem.l d1-d2,-(sp)
                move.b  RTC_MODE,d0
                and.b   #RTC_ALARM_EN|RTC_TIMER_EN,d0
                or.b    #RTC_TIMER_EN,d0        ; timer running, bank 0
                move.b  d0,RTC_MODE
                nop
                bsr     rtc_secs
                move.l  d0,d2
                moveq   #3,d1                   ; four goes at about 1.1 s each
.wait:
                moveq   #'.',d0
                bsr     progress_char
                moveq   #60,d0
                bsr     wait_frames
                tst.l   d0
                bne.s   .checked
                moveq   #1,d0                   ; no video timing to count
                bsr     delay_seconds
.checked:
                bsr     rtc_secs
                cmp.l   d2,d0
                bne.s   .ticked
                dbra    d1,.wait
                moveq   #1,d0                   ; never moved
                bra.s   .out
.ticked:
                moveq   #0,d0
.out:           movem.l (sp)+,d1-d2
                rts

; rtc_secs: out d0 = the seconds registers, tens and units, one nibble each.
rtc_secs:
                movem.l d1,-(sp)
                moveq   #0,d0
                move.b  RTC+1+1*2,d0            ; seconds, tens
                and.l   #$0F,d0
                lsl.l   #4,d0
                moveq   #0,d1
                move.b  RTC+1+0*2,d1            ; seconds, units
                and.l   #$0F,d1
                or.l    d1,d0
                movem.l (sp)+,d1
                rts

; wait_frames: d0 = frames to wait for, out d0 = 0 if the video timing never
; moved and the wait was therefore not real time.  Every step is bounded, so a
; CRTC that is not scanning cannot hang the run.
wait_frames:
                movem.l d1-d2,-(sp)
                move.l  d0,d1
                beq.s   .ok
.frame:
                move.l  #200000,d2
.low:           btst    #4,MFP_GPIP
                beq.s   .rising
                subq.l  #1,d2
                bne.s   .low
                bra.s   .dead
.rising:
                move.l  #200000,d2
.high:          btst    #4,MFP_GPIP
                bne.s   .next
                subq.l  #1,d2
                bne.s   .high
                bra.s   .dead
.next:
                subq.l  #1,d1
                bne.s   .frame
.ok:
                moveq   #1,d0
                bra.s   .out
.dead:
                moveq   #0,d0
.out:           movem.l (sp)+,d1-d2
                rts

;--- HD63450 DMAC ------------------------------------------------------------
; Channel 0 is idle at reset, so its memory address register reads back what we
; write, proving the device is decoded and alive.
test_dmac:
                movem.l d1/a0,-(sp)
                lea     DMAC,a0
                move.l  #$00A5A55A,$0C(a0)      ; ch0 MAR
                nop
                move.l  $0C(a0),d1
                and.l   #$00FFFFFF,d1
                cmp.l   #$00A5A55A,d1
                bne.s   .bad
                move.l  #$005AA5A5,$0C(a0)
                nop
                move.l  $0C(a0),d1
                and.l   #$00FFFFFF,d1
                cmp.l   #$005AA5A5,d1
                bne.s   .bad
                clr.l   $0C(a0)
                moveq   #0,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1/a0
                rts

;--- YM2151 OPM --------------------------------------------------------------
test_opm:
                move.b  OPM+3,d0                ; status register
                btst    #7,d0                   ; BUSY must be clear when idle
                bne.s   .bad
                moveq   #0,d0
                rts
.bad:           moveq   #1,d0
                rts

;--- MSM6258 ADPCM -----------------------------------------------------------
; Not tested.  Its only readable register leaves most bits open, so on real
; hardware the read returns bus float -- a healthy PRO gives $FF on one boot and
; $C0 on the next.  Proving the chip alive needs a command and an observed state
; change, which is more than this ROM can do between reset and handing over.

;--- uPD72065 FDC ------------------------------------------------------------
test_fdc:
                move.b  FDC+1,d0                ; main status register
                and.b   #$D0,d0
                cmp.b   #$80,d0                 ; RQM set, DIO clear, not busy
                bne.s   .bad
                moveq   #0,d0
                rts
.bad:           moveq   #1,d0
                rts

;--- MB89352 SCSI ------------------------------------------------------------
; Internal SCSI only exists on the SUPER, XVI, Compact and X68030; the original
; machine, ACE, EXPERT and PRO have SASI at $E96000 instead and nothing at all
; at $E96020.  BDID reports the host adapter's own ID as a single one-hot bit,
; so $00 or $FF means nothing is answering and the controller is simply not
; fitted -- report that as SKIP, not as a fault.  A controller that is present
; but broken still drives the bus and fails the one-hot check.
test_scsi:
                movem.l d1-d2,-(sp)
                moveq   #0,d1
                move.b  SCSI+1,d1               ; BDID
                and.l   #$FF,d1
                beq.s   .absent
                cmp.l   #$FF,d1
                beq.s   .absent
                move.l  d1,d2
                subq.l  #1,d2
                and.l   d1,d2                   ; clears the single set bit
                bne.s   .bad
                moveq   #0,d0
                bra.s   .out
.absent:        moveq   #2,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1-d2
                rts

;--- i8255 PPI ---------------------------------------------------------------
; Port C is configured as output, so it reads back the last value written.
test_ppi:
                movem.l d1,-(sp)
                move.b  #$92,PPI+7              ; mode 0: A in, B in, C out
                nop
                move.b  #$0A,PPI+5
                nop
                move.b  PPI+5,d1
                and.b   #$0F,d1
                cmp.b   #$0A,d1
                bne.s   .bad
                move.b  #$05,PPI+5
                nop
                move.b  PPI+5,d1
                and.b   #$0F,d1
                cmp.b   #$05,d1
                bne.s   .bad
                move.b  #$0F,PPI+5
                moveq   #0,d0
                bra.s   .out
.bad:
                move.b  #$0F,PPI+5
                moveq   #1,d0
.out:           movem.l (sp)+,d1
                rts

;--- sprite / PCG RAM --------------------------------------------------------
; Sprite RAM is not reachable in every screen mode, and video_init picks one
; where it is not: IOCS _SP_INIT ($FFC418 in the Compact IPL) opens with a guard
; that reads CRTC R20 and refuses to touch sprite hardware when the low byte is
; $16 -- exactly what video_init writes.  On real hardware a word read of
; $EB8000 bus-errors at $0B16 and returns data at $0B15.
;
; So switch to $0B15 for the test.  The display is garbled while it runs, since
; the rest of the CRTC timing still describes the old mode.  R20 is restored at
; the dispatch site -- the only place that survives a bus error.
test_sprram:
                movem.l d1-d2/a0,-(sp)
                move.w  #$0B15,CRTC+$28
                nop
                move.w  VC_R2,d2
                move.w  #$0020,VC_R2            ; text layer only
                bsr     sprite_init
                nop
                lea     SPRRAM,a0
                move.l  #(SPRRAM_END-SPRRAM)/4,d1
                bsr     mem_fill
                lea     SPRRAM,a0
                move.l  #(SPRRAM_END-SPRRAM)/4,d1
                bsr     mem_verify
                move.w  d2,VC_R2
                movem.l (sp)+,d1-d2/a0
                rts

; sprite_init: put the sprite/BG controller into a state that lets the CPU reach
; sprite RAM.
;
; The four timing registers get the values and order a stock IPL writes, tapped
; from a live boot -- they read back $FF, so post-boot state does not tell you
; what was programmed.  The control register must then get $0000, not the $0010
; an IPL leaves behind: bit 4 looks like a BG enable, and a controller fetching
; from its own RAM will not let the CPU in.  Both halves are needed.
sprite_init:
                move.w  #$00FF,SPR_HDISP
                move.w  #$00FF,SPR_HTOTAL
                move.w  #$00FF,SPR_VDISP
                move.w  #$00FF,SPR_RES
                move.w  #$0000,SPRREG           ; all BG planes off
                rts

;--- CRTC --------------------------------------------------------------------
; Not tested by readback: the register file does not read back on real silicon.
; A machine with a visibly correct 768x512 display returns $0000 from R00, R04
; and R20 alike.  See test_vidtiming, which asks the MFP instead -- and the
; screen carrying this report is itself better evidence than any readback.

;=============================================================================
; video
;=============================================================================
; wait_scanning: block until the CRTC is really scanning, or give up trying.
; Watches V-DISP on the MFP GPIP go high then low a few times, a frame each.
; Bounded at every step: a CRTC that never scans must not hang the run, and
; test_vidtiming reports that case properly a few lines later.
wait_scanning:
                movem.l d0-d2,-(sp)
                moveq   #4,d0                   ; five frames is ~90 ms at 55 Hz
.frame:
                move.l  #200000,d2
.high:          btst    #4,MFP_GPIP
                bne.s   .wasdown
                subq.l  #1,d2
                bne.s   .high
                bra.s   .out                    ; never came up: not scanning
.wasdown:
                move.l  #200000,d2
.low:           btst    #4,MFP_GPIP
                beq.s   .next
                subq.l  #1,d2
                bne.s   .low
                bra.s   .out                    ; stuck high: not scanning
.next:
                dbra    d0,.frame
.out:
                movem.l (sp)+,d0-d2
                rts

; video_init: the register values the stock IPL programs for CRTMOD 16
; (768x512, 96x32 text), read back from a live boot of the stock ROM.
video_init:
                movem.l d0/a0-a1,-(sp)
; Monitor contrast is zero out of reset and the display stays blank until it is
; set -- the stock IPL loads it from SRAM at $FF00D4, long after we run.  Wind it
; to maximum: this is a diagnostic screen and should be readable whatever the
; user's saved preference is.  The stock IPL restores their setting when we hand
; over.
                move.b  #$0F,SYSPORT+1
                lea     CRTC,a0
                lea     crtc_tab,a1
                move.w  (a1)+,(a0)              ; R00
                addq.l  #2,a0
                moveq   #7,d0
.r1:            move.w  (a1)+,(a0)+             ; R01..R08
                dbra    d0,.r1
                moveq   #10,d0
.r9:            clr.w   (a0)+                   ; R09..R19
                dbra    d0,.r9
                move.w  #$0B16,CRTC+$28         ; R20 memory / display mode
                clr.w   CRTC+$2A                ; R21 no simultaneous plane access
                clr.w   CRTC+$2C
                clr.w   CRTC+$2E
                clr.w   CRTC+$30
                move.w  #$0003,VC_R0            ; 768x512, 16 colours
                move.w  #$06E4,VC_R1            ; text above graphics
                move.w  #$0020,VC_R2            ; text layer on, everything else off
; text palette: 0 background, 1 white, 2 green, 3 red
                lea     TPAL,a0
                move.w  #$0000,(a0)+
                move.w  #$FFFE,(a0)+
                move.w  #$F800,(a0)+
                move.w  #$07C0,(a0)+
                movem.l (sp)+,d0/a0-a1
                rts

crtc_tab:
                dc.w    $0089                   ; R00 horizontal total
                dc.w    $000E,$001C,$007C       ; R01..R03 horizontal timing
                dc.w    $0237,$0005,$0028,$0228 ; R04..R07 vertical timing
                dc.w    $001B                   ; R08 horizontal adjust

tvram_clear:
                movem.l d0-d2/a0,-(sp)
                lea     TVRAM,a0
                moveq   #0,d0
                move.l  #(TVRAM_RESV-TVRAM)/4,d1
.chunk:
                move.l  d1,d2
                cmp.l   #$8000,d2
                bls.s   .small
                move.l  #$8000,d2
.small:
                sub.l   d2,d1
                subq.w  #1,d2
.loop:          move.l  d0,(a0)+
                dbra    d2,.loop
                tst.l   d1
                bne.s   .chunk
                movem.l (sp)+,d0-d2/a0
                rts

;=============================================================================
; text output
;=============================================================================
; putchar: d0 = char, d1 = colour, cursor in w_col / w_row.  Colour is a plane
; mask: the glyph row goes to plane 0 for bit 0 and plane 1 for bit 1, and to
; blank for the planes it is not in, so a cell is always fully overwritten.
putchar:
                movem.l d0-d5/a0-a2,-(sp)
                and.l   #$FF,d0
                lsl.l   #4,d0
                lea     ANK8X16,a0
                adda.l  d0,a0                   ; glyph source
                moveq   #0,d2
                move.w  w_row,d2
                lsl.l   #4,d2                   ; row -> first scanline
                mulu    #TV_STRIDE,d2
                moveq   #0,d3
                move.w  w_col,d3
                add.l   d3,d2
                lea     TVRAM,a1
                adda.l  d2,a1                   ; plane 0 destination
                movea.l a1,a2
                adda.l  #TVRAM_PLANE,a2         ; plane 1 destination
                moveq   #15,d4
.row:
                move.b  (a0)+,d5
                btst    #0,d1
                bne.s   .p0set
                clr.b   (a1)
                bra.s   .p1
.p0set:         move.b  d5,(a1)
.p1:
                btst    #1,d1
                bne.s   .p1set
                clr.b   (a2)
                bra.s   .next
.p1set:         move.b  d5,(a2)
.next:
                lea     TV_STRIDE(a1),a1
                lea     TV_STRIDE(a2),a2
                dbra    d4,.row
                addq.w  #1,w_col
                movem.l (sp)+,d0-d5/a0-a2
                rts

newline:
                move.w  #LEFT_MARGIN,w_col
                addq.w  #1,w_row
                cmp.w   #SCR_ROWS,w_row
                blt.s   .ok
                bsr     scroll_up
                move.w  #SCR_ROWS-1,w_row
.ok:            rts

; scroll_up: shift both text planes up one row and blank the last one, so a
; report longer than the screen does not overwrite its own final line.  Only
; runs on overflow, and copies about 124K, so it costs nothing on a report that
; fits.
scroll_up:
                movem.l d0-d2/a0-a2,-(sp)
                lea     TVRAM,a2
                moveq   #1,d2                   ; two planes
.plane:
                movea.l a2,a0                   ; destination: row 0
                lea     16*TV_STRIDE(a2),a1     ; source: row 1
                move.w  #(SCR_ROWS-1)*16*TV_STRIDE/4-1,d0
.copy:          move.l  (a1)+,(a0)+
                dbra    d0,.copy
                moveq   #0,d1                   ; a0 now sits at the last row
                move.w  #16*TV_STRIDE/4-1,d0
.clr:           move.l  d1,(a0)+
                dbra    d0,.clr
                adda.l  #TVRAM_PLANE,a2
                dbra    d2,.plane
                movem.l (sp)+,d0-d2/a0-a2
                rts

; print_str: a0 = asciiz, d1 = colour.
print_str:
                movem.l d0/a0,-(sp)
.loop:          moveq   #0,d0
                move.b  (a0)+,d0
                beq.s   .done
                bsr     putchar
                bra.s   .loop
.done:          movem.l (sp)+,d0/a0
                rts

; print_dec: d0 = unsigned value (<= 65535), d1 = colour.  Screen and serial.
print_dec:
                movem.l d0-d3/a0,-(sp)
                and.l   #$FFFF,d0
                lea     w_buf_end,a0
                clr.b   -(a0)
                moveq   #10,d2
.loop:
                divu    d2,d0
                move.l  d0,d3
                swap    d3                      ; d3.w = remainder
                add.b   #'0',d3
                move.b  d3,-(a0)
                and.l   #$FFFF,d0               ; keep the quotient
                bne.s   .loop
                bsr     print_str
                bsr     serial_str
                movem.l (sp)+,d0-d3/a0
                rts

; hex_to_buf: d0 = value, d2 = digit count.  Out a0 = asciiz text in w_buf.
hex_to_buf:
                movem.l d0/d2-d3,-(sp)
                lea     w_buf_end,a0
                clr.b   -(a0)
                subq.l  #1,d2
.loop:          move.l  d0,d3
                and.l   #$0F,d3
                add.b   #'0',d3
                cmp.b   #'9',d3
                bls.s   .digit
                addq.b  #7,d3                   ; '9'+1.. -> 'A'..'F'
.digit:         move.b  d3,-(a0)
                lsr.l   #4,d0
                dbra    d2,.loop
                movem.l (sp)+,d0/d2-d3
                rts

; print_hex: d0 = value, d2 = digit count.  Screen and serial.
print_hex:
                movem.l a0,-(sp)
                bsr     hex_to_buf
                bsr     detail_str
                movem.l (sp)+,a0
                rts

; print_hex_scr: as print_hex but screen only, for the test_dram progress
; address -- print_hex would drown the serial log at once per 8K.
print_hex_scr:
                movem.l d1/a0,-(sp)
                bsr     hex_to_buf
                moveq   #COL_NORMAL,d1
                bsr     print_str
                movem.l (sp)+,d1/a0
                rts

; print_hexdollar: d0 = value, d2 = digits.  Prints "$xxxxxxxx".
print_hexdollar:
                movem.l d0/a0,-(sp)
                lea     s_dollar,a0
                bsr     detail_str
                movem.l (sp)+,d0/a0
                bra     print_hex

; detail_str: a0 = asciiz, to screen and serial.
detail_str:
                movem.l d1/a0,-(sp)
                moveq   #COL_NORMAL,d1
                bsr     print_str
                bsr     serial_str
                movem.l (sp)+,d1/a0
                rts

;=============================================================================
; test dispatch
;=============================================================================
; run_test / run_test_opt: a0 = test name, a1 = test routine.
;
; Prints the name, establishes bus-error recovery around the call, runs the test
; and prints the verdict.  A bus error means nothing responded at all: run_test
; calls that FAIL, run_test_opt calls it SKIP for genuinely optional hardware.
; Either way a device that answers but returns bad data fails on its data.
run_test:
                moveq   #5,d2                   ; verdict if the probe faults
                bra.s   run_test_common
run_test_opt:
                moveq   #2,d2                   ; SKIP if the probe faults
run_test_common:
                movem.l d1-d2/a0-a4,-(sp)
; The fault verdict must live in a work word, not a register: fault_handler
; unwinds the stack straight to .fault, so the test's own movem restore never
; runs and whatever it left in d2 would survive instead.
                move.w  d2,w_fverdict
                clr.w   w_fdetail
                clr.w   w_sumshow
                move.w  #$FFFF,w_progcol
                move.w  #$FFFF,w_addrcol
                bsr     line_start
                lea     .fault,a3
                move.l  a7,a4
                jsr     (a1)
                bra.s   .done
.fault:
                moveq   #0,d0
                move.w  w_fverdict,d0
.done:
                bsr     verdict
                movem.l (sp)+,d1-d2/a0-a4
                rts

;=============================================================================
; result line formatting
;=============================================================================
; line_start: a0 = test name.  Prints it and pads with dots so that every
; verdict lands in the same column, on screen and on the serial line.
line_start:
                movem.l d0-d1/a0,-(sp)
                move.l  a0,-(sp)
                moveq   #COL_NORMAL,d1
                bsr     print_str
                move.l  (sp)+,a0
                bsr     serial_str
.pad:
                cmp.w   #RESULT_COL,w_col
                bge.s   .done
                moveq   #'.',d0
                moveq   #COL_NORMAL,d1
                bsr     putchar
                moveq   #'.',d0
                bsr     serial_char
                bra.s   .pad
.done:
                moveq   #' ',d0
                moveq   #COL_NORMAL,d1
                bsr     putchar
                moveq   #' ',d0
                bsr     serial_char
                movem.l (sp)+,d0-d1/a0
                rts

; verdict: d0 = 0 pass, 2 skip, 6 the RAM size line, anything else fail.
; Only a fail is counted.
verdict:
                movem.l d0-d2/a0,-(sp)
                bsr     progress_clear
                cmp.l   #6,d0
                beq.s   .size
                cmp.l   #2,d0
                beq.s   .skip
                tst.l   d0
                bne.s   .fail
                lea     s_ok,a0
                moveq   #COL_GOOD,d1
                bsr     print_str
                lea     s_ok,a0
                bsr     serial_str
                bra.s   .done
.size:
; Not a pass/fail at all: the line reports how much memory was found, and the
; pattern test on the next line is what passes or fails on it.
                bsr     print_ramsize
                bra.s   .done
.skip:
                lea     s_skip,a0
                moveq   #COL_NORMAL,d1
                bsr     print_str
                lea     s_skip,a0
                bsr     serial_str
                bra.s   .done
.fail:
                lea     s_fail,a0
                moveq   #COL_BAD,d1
                bsr     print_str
                lea     s_fail,a0
                bsr     serial_str
                addq.w  #1,w_fail
.done:
                bsr     print_sum
                bsr     newline
                bsr     serial_crlf
                tst.w   w_fdetail
                bne.s   .detail
                movem.l (sp)+,d0-d2/a0
                rts
.detail:
; Indented continuation under the FAIL.  Both kinds open with the address and
; close with w_fgot, so only the middle differs:
;   $00123456 exp $5A5AA5A5 got $5A5AA5A4
;   $00100000 stuck bits $00000040
                move.w  w_fdetail,d1
                clr.w   w_fdetail
                lea     s_indent,a0
                bsr     detail_str
                move.l  w_faddr,d0
                moveq   #8,d2
                bsr     print_hexdollar
                cmp.w   #2,d1
                beq.s   .stuck
                lea     s_exp,a0
                bsr     detail_str
                move.l  w_fexp,d0
                moveq   #8,d2
                bsr     print_hexdollar
                lea     s_got,a0
                bra.s   .last
.stuck:
                lea     s_stuck,a0
.last:
                bsr     detail_str
                move.l  w_fgot,d0
                moveq   #8,d2
                bsr     print_hexdollar
                bsr     newline
                bsr     serial_crlf
                movem.l (sp)+,d0-d2/a0
                rts

; print_sum: appends " (xxxxxxxx)" to a verdict when the test set w_sumshow.
; Used by the two checksum lines, which report a value as well as a verdict.
print_sum:
                movem.l d0/d2/a0,-(sp)
                tst.w   w_sumshow
                beq.s   .out
                clr.w   w_sumshow
                lea     s_lparen,a0
                bsr     detail_str
                move.l  w_sum,d0
                moveq   #8,d2
                bsr     print_hex
                lea     s_rparen,a0
                bsr     detail_str
.out:           movem.l (sp)+,d0/d2/a0
                rts

; print_ramsize: writes the detected size, e.g. 4096K, where a verdict would go.
; Called from verdict for the size line, so the line is already started.
print_ramsize:
                movem.l d0-d1/a0,-(sp)
                move.l  w_ramsize,d0
                lsr.l   #8,d0
                lsr.l   #2,d0                   ; bytes -> KB
                moveq   #COL_NORMAL,d1
                bsr     print_dec
                lea     s_kb,a0
                moveq   #COL_NORMAL,d1
                bsr     print_str
                lea     s_kb,a0
                bsr     serial_str
                movem.l (sp)+,d0-d1/a0
                rts

;=============================================================================
; RS-232C on SCC channel A
;=============================================================================
; SCC PCLK is 5MHz; time constant = PCLK / (2 * baud * 16) - 2.
;
; NOTE: MAME's x68000 driver wires SCC channel B to the mouse and leaves
; channel A's TxD unconnected, so this path cannot be observed under emulation.
; It is checked there by watching writes to $E98007 instead.
SCC_TC          equ     14                      ; ~9600 baud, 8N1

serial_init:
                movem.l d0/a0,-(sp)
                move.w  #1,w_serial             ; assume dead until proven alive
                lea     SCC_ACTL,a0
                move.b  #9,(a0)
                move.b  #$C0,(a0)               ; WR9  force hardware reset
                moveq   #63,d0
.wait:          nop
                dbra    d0,.wait
; Order matters: the transmitter must not be enabled until its clock source is
; configured, or it latches a rate of zero and never reports ready.
                move.b  #4,(a0)
                move.b  #$44,(a0)               ; WR4  x16 clock, 1 stop, no parity
                move.b  #3,(a0)
                move.b  #$C0,(a0)               ; WR3  rx 8 bits, rx still disabled
                move.b  #5,(a0)
                move.b  #$60,(a0)               ; WR5  tx 8 bits, tx still disabled
                move.b  #11,(a0)
                move.b  #$50,(a0)               ; WR11 tx and rx clock from BRG
                move.b  #14,(a0)
                move.b  #$00,(a0)               ; WR14 BRG off while loading it
                move.b  #12,(a0)
                move.b  #(SCC_TC&$FF),(a0)      ; WR12 time constant, low
                move.b  #13,(a0)
                move.b  #(SCC_TC>>8),(a0)       ; WR13 time constant, high
                move.b  #14,(a0)
                move.b  #$03,(a0)               ; WR14 BRG on, source = PCLK
                move.b  #3,(a0)
                move.b  #$C1,(a0)               ; WR3  rx enable
                move.b  #5,(a0)
                move.b  #$68,(a0)               ; WR5  tx enable
; Give the transmitter a bounded chance to report ready.  If it never does,
; leave serial disabled rather than stalling every line of output on a machine
; whose SCC is dead or absent.
                move.w  #$0FFF,d0
.ready:
                btst    #2,SCC_ACTL             ; RR0 bit 2 = tx buffer empty
                beq.s   .notyet
                clr.w   w_serial
                bra.s   .out
.notyet:
                dbra    d0,.ready
.out:
                movem.l (sp)+,d0/a0
                rts

; serial_char: d0 = byte.  Bounded wait, so a dead SCC cannot hang the run.
serial_char:
                tst.w   w_serial
                bne.s   .skip
                movem.l d0-d1,-(sp)
                move.l  d0,d1
                move.w  #$0FFF,d0
.wait:
                btst    #2,SCC_ACTL             ; RR0 bit 2 = tx buffer empty
                bne.s   .send
                dbra    d0,.wait
                bra.s   .out
.send:
                move.b  d1,SCC_ADATA
.out:           movem.l (sp)+,d0-d1
.skip:          rts

serial_str:
                movem.l d0/a0,-(sp)
.loop:          moveq   #0,d0
                move.b  (a0)+,d0
                beq.s   .done
                bsr     serial_char
                bra.s   .loop
.done:          movem.l (sp)+,d0/a0
                rts

serial_crlf:
                movem.l d0,-(sp)
                moveq   #13,d0
                bsr     serial_char
                moveq   #10,d0
                bsr     serial_char
                movem.l (sp)+,d0
                rts

; serial_drain: wait until the transmitter has actually shifted the last byte
; onto the wire, not merely accepted it.
;
; serial_char waits for "tx buffer empty" (RR0 bit 2) before writing, which frees
; the holding register while the byte before it is still in the shift register,
; so when the final character returns there are up to two still in flight.
; Standalone that is harmless -- the CPU parks in STOP and they drain on their
; own -- but the injected build jumps straight to the IPL, which resets the SCC
; and cuts them off mid-transmission.  On real hardware that lost the tail of
; the last line; the serial log ended "...to the IP".
;
; RR1 bit 0 is All Sent.  The SCC's register pointer auto-clears after each
; access, so register 1 has to be re-selected on every poll.  Bounded like every
; other wait here: a dead SCC must not hold the machine off the IPL.
serial_drain:
                tst.w   w_serial
                bne.s   .skip
                movem.l d0,-(sp)
                move.w  #$7FFF,d0
.wait:
                move.b  #1,SCC_ACTL             ; point at RR1
                btst    #0,SCC_ACTL             ; bit 0 = All Sent
                bne.s   .out
                dbra    d0,.wait
.out:           movem.l (sp)+,d0
.skip:          rts

;=============================================================================
; delay_seconds: d0 = seconds
;=============================================================================
; Calibrated for a 10MHz 68000; a 16MHz XVI Compact runs it about 1.6x faster.
; Prefer wait_frames where real time matters -- see test_rtcosc.
delay_seconds:
                movem.l d0-d2,-(sp)
                move.l  d0,d2
                beq.s   .out
.second:
                move.w  #$FFFF,d0
.outer:
                move.w  #6,d1
.inner:         nop
                dbra    d1,.inner
                dbra    d0,.outer
                subq.l  #1,d2
                bne.s   .second
.out:           movem.l (sp)+,d0-d2
                rts

;=============================================================================
; data
;=============================================================================
                even
s_banner:       dc.b    'SHARP X68000  TEST-IPL  v0.36',0
s_ok:           dc.b    'OK',0
s_fail:         dc.b    'FAIL',0
s_skip:         dc.b    'SKIP',0
s_allok:        dc.b    'ALL TESTS PASSED',0
s_failed:       dc.b    ' TEST(S) FAILED',0
s_halted:       dc.b    'Testing done! You can shut down the computer.',0
s_booting:      dc.b    'EXITING',0
s_kb:           dc.b    'K',0
s_indent:       dc.b    '  ',0
s_dollar:       dc.b    '$',0
s_exp:          dc.b    ' exp ',0
s_got:          dc.b    ' got ',0
s_stuck:        dc.b    ' stuck bits ',0
s_lparen:       dc.b    ' (',0
s_rparen:       dc.b    ')',0
; Human68k SRAM signature: full-width X in Shift-JIS, then "68000W"
s_sramsig:      dc.b    $82,$77,'68000W'

n_tvram:        dc.b    'Text VRAM',0
n_cgrom:        dc.b    'CGROM checksum',0
n_romsum:       dc.b    'ROM checksum',0
n_gvram:        dc.b    'Graphic VRAM',0
n_dram:         dc.b    'Main RAM',0
n_ramsize:      dc.b    'Main RAM size',0
n_ramchk:       dc.b    'Main RAM vs SRAM',0
n_sram:         dc.b    'SRAM signature',0
n_mfp:          dc.b    'MFP MC68901',0
n_vidtim:       dc.b    'CRTC video timing',0
n_rtc:          dc.b    'RTC RP5C15',0
n_rtcosc:       dc.b    'RTC oscillator',0
n_dmac:         dc.b    'DMAC HD63450',0
n_opm:          dc.b    'OPM YM2151',0
n_fdc:          dc.b    'FDC uPD72065',0
n_scsi:         dc.b    'SCSI MB89352',0        ; optional: not on Ace/Pro/EXPERT
n_ppi:          dc.b    'PPI i8255',0
n_sprram:       dc.b    'Sprite RAM',0

                even
testipl_end:
