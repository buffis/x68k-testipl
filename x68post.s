;-----------------------------------------------------------------------------
; x68post.s -- Power-On Self Test for the Sharp X68000 family
;
; Assembles with vasm (Motorola syntax) to a raw binary that build.py pads into
; a complete 128K IPL ROM image.  This is a standalone diagnostic ROM: it takes
; the machine at reset, runs the tests, reports, and stops.  It does not boot
; Human68k and contains no Sharp code -- you swap it into the IPL sockets to
; test a machine and swap the stock ROMs back afterwards.
;
; Constraints this code works under:
;   * It runs at reset, so nothing is initialised: no stack, no vector table,
;     no video, no RAM.  Main RAM is one of the things under test, so the
;     stack must not live there -- off-screen text VRAM is used instead.
;   * Absolute, position-dependent code.  POST_BASE must match build.py.
;   * Nothing runs after us, so the tests are free to leave hardware dirty.
;-----------------------------------------------------------------------------

; Where the code sits in the ROM.  Normally supplied by build.py with
; -DPOST_BASE=...; the default matches it.  The 68000 fetches SSP from $FF0000
; and its reset PC from $FF0004, so the code starts just past those two
; longwords.  POST_BASE must be 4-aligned so the checksum field in the header
; lands on a longword boundary, which the ROM checksum loop relies on to skip
; its own.
                ifnd    POST_BASE
POST_BASE       equ     $FF0010
                endif

;--- hardware ----------------------------------------------------------------
GVRAM           equ     $C00000
; Graphic VRAM is 512K of physical memory presented in a 2MB window; how the
; window folds onto it depends on CRTC R20, so the test sets R20 explicitly.
GVRAM_TEST_END  equ     $C80000
TVRAM           equ     $E00000         ; 4 planes, 128K each, contiguous
TVRAM_END       equ     $E80000
; Top 4K of plane 3 = text lines 992-1023, which are off the bottom of a
; 512-line screen.  The stack and work area live there, so it is held back
; from the text VRAM test.
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
ADPCM           equ     $E92000
FDC             equ     $E94000
SCSI            equ     $E96020         ; register n at SCSI+1+2n
SCC             equ     $E98000
PPI             equ     $E9A000
; MIDI board (YM3802) -- Sharp's CZ-6BM1 or a compatible -- on the expansion
; bus.  Register n is the odd byte at MIDI+1+2n; an empty slot drives no DTACK,
; so probing it bus-errors.
MIDI            equ     $EAFA00
MIDI_WDR        equ     MIDI+1+3*2      ; reg 3 reads back the last byte written
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

;--- POST work area, at the very top of GVRAM (excluded from the GVRAM test) --
WORK            equ     $E7FF00
w_col           equ     WORK+0          ; word  cursor column
w_row           equ     WORK+2          ; word  cursor row
w_fail          equ     WORK+4          ; word  failure count
w_buserr        equ     WORK+6          ; word  bus error latch
w_ramsize       equ     WORK+8          ; long  detected main RAM bytes
w_tvram         equ     WORK+12         ; word  TVRAM result, tested pre-video
w_serial        equ     WORK+14         ; word  non-zero once serial is given up on
; Detail for the line under a FAIL verdict.  run_test clears w_fdetail before
; every test, so a test that sets it owns the line and nothing stale survives.
w_faddr         equ     WORK+16         ; long  address of the first bad longword
w_fexp          equ     WORK+20         ; long  what should have been there
w_fgot          equ     WORK+24         ; long  what was actually read
w_fdetail       equ     WORK+28         ; word  detail kind: 0 none, 1 exp/got, 2 stuck bits
w_fverdict      equ     WORK+46         ; word  verdict to use if the test faults
w_addrcol       equ     WORK+44         ; word  column the RAM address field sits
                                        ;       at, $FFFF when none is open
w_progcol       equ     WORK+30         ; word  column a run of progress marks began
                                        ;       at, $FFFF when none is open
w_buf           equ     WORK+32         ; string build buffer

STACK_TOP       equ     $E7FF00         ; grows down through $E7F000-$E7FEFF

MEM_XOR         equ     $5A5AA5A5       ; address-derived fill pattern

                org     POST_BASE

;=============================================================================
; header -- fixed layout so build.py can patch the checksums without needing
; to read symbols out of the assembler listing.
;   +0  branch to the entry point (the reset vector points here)
;   +4  expected ROM checksum
;=============================================================================
                bra.w   post_entry
romsum_ref:     dc.l    0

;=============================================================================
; entry
;=============================================================================
post_entry:
                move.w  #$2700,sr               ; supervisor, interrupts off
                reset                           ; reset external devices

;--- let low memory be written -----------------------------------------------
; The supervisor area register governs what may be written to low memory, and
; it comes up in an undefined state at power-on.  A stock IPL clears it within
; a few instructions of reset -- PC $FF00B0 on IPL 1.0, before it touches
; anything else -- and we never did.
;
; On a real PRO that cost us every cold boot: writes above $400 hung the bus
; while reads of the same addresses worked, the vector table below $400 stayed
; writable, and a warm reset was always fine because the previous run had left
; the register clear.  MAME does not implement this register at all (areaset_w
; is a TODO in its x68000 driver), so nothing in emulation could ever have
; shown it.
                move.b  #0,AREASET

;--- make video RAM decode predictable before anything touches it ------------
; Text VRAM is only a flat array while CRTC R21 has simultaneous-plane access
; and the access mask switched off, and R21 is undefined at power-on.  These
; two stores have no dependencies, so they are safe to do with no stack.
                move.w  #$0B16,CRTC+$28         ; R20 memory / display mode
                clr.w   CRTC+$2A                ; R21 plain, unmasked writes

;--- find somewhere to put a stack -------------------------------------------
; Main RAM is under test so it cannot hold the stack, and graphic VRAM folds
; onto itself depending on R20.  Off-screen text VRAM is flat and independent
; of both, so probe a window there using registers only.
                lea     TVRAM_RESV,a0           ; $E7F000
                move.l  #$5A5AA5A5,d0
                move.l  #$0F0FF0F0,d1
                move.l  d0,(a0)
                move.l  d1,4(a0)
                move.l  d0,-8(a0)
                cmp.l   (a0),d0
                bne.s   .no_tvram
                cmp.l   4(a0),d1
                bne.s   .no_tvram
                cmp.l   -8(a0),d0
                bne.s   .no_tvram
                lea     STACK_TOP,a7
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
; Install bus and address error handlers before touching any hardware, so that
; probing something which is not fitted on this model cannot derail the POST.
; They need a vector table in low RAM; if that is dead there is nothing that
; can be done about it, and test_dram reports it.
;--- the whole vector table, not just two of them -----------------------------
; Both IPLs fill all 256 exception vectors as their first act after RESET, and
; we never did -- we set bus error and address error and left the other 254
; holding whatever the RAM powered up with.
;
; That is not survivable on a cold boot.  Level 7 is non-maskable, so the
; move.w #$2700,sr above does not protect us: any interrupt the hardware raises
; from its undefined power-on state vectors through a random longword and the
; machine is gone.  A warm reset hides it, because by then something has been
; through low memory and left it looking like code addresses rather than noise.
;
; Point everything at a handler that returns, then put the two we care about
; back on top.
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
; The HD63450 comes up with undefined registers, and a channel that powers up
; armed will arbitrate for the bus and run transfers of its own.  A CPU stalled
; mid-write with no bus error is exactly what a DMA controller holding the bus
; looks like, and the POST has never touched the DMAC before test_dram -- exbios
; programs it, we did not.
;
; Abort every channel, idle it, then clear its status.  Guarded, because this is
; the first device the POST touches and a fault here must not jump through a
; stale a3.
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
; Text VRAM is refreshed by the display.  Testing it before the CRTC is
; generating timing means filling half a megabyte and verifying it some
; milliseconds later with nothing holding the cells up, and on a real PRO that
; fails every cold boot while passing after every reset -- because a reset
; leaves the CRTC still scanning from the previous run.  The stack probe above
; survives either way: it writes and reads back within microseconds.
;
; So bring the display up, wait for it to actually scan, and only then test.
                bsr     video_init              ; CRTC + video controller + palette
                bsr     wait_scanning

;--- get the stack out of main RAM ------------------------------------------
; The probe at entry runs before the CRTC is programmed, and on a cold machine
; text VRAM does not answer then -- so it takes the fallback and puts the stack
; at $2000, in main RAM.  That is a trap: test_dram patterns from $400 upwards
; and walks straight over it, destroying the return addresses underneath.  The
; machine then jumps through a corrupted rts and stops dead, which looks exactly
; like a stalled bus.  It is what stalled a real PRO at $1C00 -- the first slice
; to reach $2000 -- and at $400 in earlier builds, whose slices were large
; enough to span it from the start.
;
; The display is scanning now, so ask again.  Straight-line code with nothing
; live on the stack, so a7 can simply be reloaded.
                lea     TVRAM_RESV,a0
                move.l  #$5A5AA5A5,d0
                move.l  #$0F0FF0F0,d1
                move.l  d0,(a0)
                move.l  d1,4(a0)
                move.l  d0,-8(a0)
                cmp.l   (a0),d0
                bne.s   .keep_stack
                cmp.l   4(a0),d1
                bne.s   .keep_stack
                cmp.l   -8(a0),d0
                bne.s   .keep_stack
                lea     STACK_TOP,a7
.keep_stack:

; The work area lives in text VRAM, so it is only held up once the display is
; scanning.  Everything here used to be set before video_init and had to
; survive the whole of test_tvram unrefreshed: on a cold boot w_progcol lost
; its $FFFF, progress_clear then took the 0 for a real column and wiped the
; first report line's label.  A warm reset was fine because refresh never
; stopped.  So initialise after the display is up, not before.
                clr.w   w_fail
                clr.w   w_buserr
                clr.l   w_ramsize
                clr.w   w_col
                clr.w   w_row
                move.w  #$FFFF,w_addrcol
                clr.w   w_fdetail               ; the Text VRAM line does not go
                                                ; through run_test, so nothing
                                                ; else would clear it, and cold
                                                ; VRAM holds garbage
                move.w  #$FFFF,w_progcol

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

; The diagnostic page runs BEFORE the tests, not after.  It used to come last,
; which made it useless on the machine it exists for: a real PRO stalls inside
; test_dram on a cold boot, so the run never reached the diagnostics at all.
; Raw values are the whole point of this build, so they come first and the
; ordinary test sequence follows -- if that then hangs, the page has already
; been printed and read.
                ifd     DIAG
                bsr     diag_section
                endif

;=============================================================================
; the tests
;=============================================================================
; Two groups, in this order: everything that exercises a device first, then
; everything that exercises memory.  Memory is second on purpose -- main RAM
; is the slowest test and the one most likely to hang a sick machine, so by
; the time it runs the whole report above it is already on screen.

;--- internals ---------------------------------------------------------------
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

                lea     n_midi,a0
                lea     test_midi,a1
                bsr     run_test_opt

;--- memory ------------------------------------------------------------------
                lea     n_romsum,a0
                lea     test_romsum,a1
                bsr     run_test

                bsr     report_cgsum

; The verdict was worked out at startup, before anything could be printed --
; the display has to be trusted before the report means anything.  This is
; where it gets said, with the rest of the memory.
                lea     n_tvram,a0
                bsr     line_start
                move.w  w_tvram,d0
                and.l   #$FFFF,d0
                bsr     verdict

                lea     n_gvram,a0
                lea     test_gvram,a1
                bsr     run_test

; Sprite RAM access bus-errors on a real X68000 PRO -- nothing drives DTACK
; with the sprite plane disabled, which is how the POST leaves it.  run_test
; would call that a failure; run_test_opt calls a fault SKIP, while RAM that
; answers and gives back the wrong pattern still fails on its data.
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
; Pointing this at a plain rte is not enough.  If something has latched an NMI
; -- and from cold the hardware is in whatever state power-up left it -- an rte
; returns straight into it again, and the machine spins in an interrupt loop
; that looks exactly like a stalled bus.
;
; exbios installs a real handler here and its first instruction writes $0C to
; the system port, which is what acknowledges the interrupt.  Do the same, then
; return.
nmi_handler:
                move.b  #$0C,SYSPORT+7
                rte

; vec_ignore: anything we have not given a real handler to.  Returning is the
; right answer for a spurious interrupt; for a genuine fault it is no worse than
; the garbage address it replaces.
vec_ignore:
                rte

dead_end:
; No usable memory anywhere: nothing can be reported.  Make the failure at
; least visible on a scope by rattling the system port.
                move.b  #$0F,SYSPORT+1
                move.b  #$00,SYSPORT+1
                bra.s   dead_end

;=============================================================================
; generic memory fill / verify
;   in:  a0 = base, d1 = longword count (32 bit)
;   out: d0 = 0 pass / 1 fail, a0 = end (fill) or failing address (verify)
; Pattern is derived from the address so that stuck or swapped address lines
; show up as well as stuck data bits.
;=============================================================================
mem_fill:
                movem.l d1-d3/a1,-(sp)
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
                movem.l (sp)+,d1-d3/a1
                rts

mem_verify:
                movem.l d1-d3/a1,-(sp)
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
                movem.l (sp)+,d1-d3/a1
                rts

;=============================================================================
; test bodies -- each returns d0 = 0 for pass, non-zero for fail
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
; Reported, not judged.  More than one CGROM revision exists, and this ROM
; deliberately carries no copy of Sharp's to compare against, so a verdict here
; would be a guess -- it was the likeliest source of a false FAIL on a healthy
; machine.  The value is stable for a given machine, so record it and compare
; against another of the same model.
report_cgsum:
                movem.l d0-d2/a0,-(sp)
                lea     n_cgrom,a0
                bsr     line_start
                lea     CGROM,a0
                moveq   #2,d2                   ; 196608 longwords = 3 x 65536
                moveq   #0,d0
.chunk:
                move.w  #$FFFF,d1
.loop:          add.l   (a0)+,d0
                dbra    d1,.loop
                dbra    d2,.chunk
                moveq   #8,d2
                bsr     print_hex
                bsr     newline
                bsr     serial_crlf
                movem.l (sp)+,d0-d2/a0
                rts

;--- IPL ROM checksum --------------------------------------------------------
; Sums the whole 128K ROM except the four bytes holding the reference value,
; so the ROM verifies the very code you are running.  This is a check on the
; EPROM burn, not on the machine -- the machine's own IPL is out of its socket
; while this ROM is in it.
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
                sub.l   romsum_ref,d0
                movem.l (sp)+,d1/a0-a1
                rts

;--- graphic VRAM ------------------------------------------------------------
; Skips the top 4K, which holds the stack and work area.
; The 2MB graphic VRAM window folds onto 512K of real memory, and how it folds
; is set by CRTC R20 bits 8-11.  Switch to the mode that maps the first 512K
; through as plain 16-bit words, test that, then put R20 back for the display.
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
; The result goes in w_ramsize and is reported as the verdict of this line, so
; the size is on screen before the pattern pass below it starts running.
test_ramsize:
                movem.l d1-d6/a0-a4,-(sp)

; The first kilobyte must work before exception vectors can be installed.
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
; Sizing stops at the first megabyte whose tag does not read back, but that
; happens both when there is no memory there and when there is memory with a
; stuck bit.  Left alone, a failing chip would quietly be reported as a smaller
; machine.  Memory that is present still stores most of what you write, so
; write all-zeroes and all-ones and count how many bits misbehave: a handful
; means a faulty device, everything means there is nothing there at all.
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
;--- phase 2: pattern test from $400 up, leaving the vector table alone ------
; Never pattern over our own stack.  If it is still in main RAM then the
; fallback was taken and the display probe did not rescue it; testing anyway
; would overwrite the return addresses under a7 and hang.  Say so instead.
                cmp.l   #TVRAM,a7
                bcc.s   .stack_is_safe
                moveq   #2,d0                   ; SKIP rather than self-destruct
                bra     .out
.stack_is_safe:
                lea     .bad,a3
; A megabyte at a time, so the marks track the part that actually takes the
; time.  Everything is filled before anything is verified, so aliasing between
; megabytes still shows up -- the slicing is only there to punctuate it.
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
                bne.s   .bad
                tst.l   d6
                bne.s   .pver
                moveq   #0,d0
                bra.s   .pout

; .pwords: d6 = longwords from $400 to the top of memory.
.pwords:
                move.l  w_ramsize,d6
                sub.l   #$400,d6
                lsr.l   #2,d6
                rts

; .pslice: take up to 2048 longwords (8K) off d6 and return it in d1.
;
; The slice size only sets how precisely the address on screen names a stall --
; it is not a hardware workaround.  It was briefly cut to 512 while chasing what
; looked like a limit on consecutive RAM writes on a real PRO; that turned out
; to be this code overwriting its own stack, so the small slices bought nothing
; and cost about twelve seconds at 12 MB.
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
; Shown on screen as a letter and an address overwritten in place, because 80
; slices per 10 MB would run off the end of the line as marks but a number
; always fits -- and it says exactly which 128K block a stall happened in,
; which is the whole point.  Written before the slice, not after, so the
; address on screen is the one being worked on when it stops.
;
; The serial line still gets a plain dot per slice; it has no cursor to rewind.
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
.pout:
                bra.s   .out                    ; .out is out of bra.s range
.bad:
                moveq   #1,d0
                bra.s   .out
.nosize:
                moveq   #2,d0                   ; SKIP: test_ramsize already
                                                ; failed and said why
.out:
                movem.l (sp)+,d1-d6/a0-a4
                rts


; dram_tick: one dot per megabyte cleared, so a machine that stalls somewhere in
; test_dram says where rather than just sitting on an unfinished line.
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

; print_hex_scr: d0 = value, d2 = digit count.  Screen only -- print_hex sends
; to the serial line as well, which would drown the log when it is called once
; per 128K.
print_hex_scr:
                movem.l d0-d4/a0,-(sp)
                lea     w_buf+12,a0
                clr.b   -(a0)
                move.l  d2,d4
                subq.l  #1,d4
.loop:          move.l  d0,d3
                and.l   #$0F,d3
                add.b   #'0',d3
                cmp.b   #'9',d3
                bls.s   .digit
                addq.b  #7,d3
.digit:         move.b  d3,-(a0)
                lsr.l   #4,d0
                dbra    d4,.loop
                moveq   #COL_NORMAL,d1
                bsr     print_str
                movem.l (sp)+,d0-d4/a0
                rts

; progress_screen: as progress_char but screen only, for marks that would flood
; the serial log if every one of them were sent.
progress_screen:
                movem.l d0-d1,-(sp)
                cmp.w   #$FFFF,w_progcol
                bne.s   .have
                move.w  w_col,w_progcol
.have:
                moveq   #COL_NORMAL,d1
                bsr     putchar
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

; Bus / address error handler.  A group 0 fault cannot be resumed, so the only
; recovery is to discard the frame and jump somewhere known-good; a3 and a4
; are set up by whichever probe is running.
fault_handler:
                move.w  #1,w_buserr
                movea.l a4,a7
                jmp     (a3)

; Human68k records the memory size it last configured at $ED0008.  (Under MAME
; that address is faked from the configured RAM size rather than read from
; NVRAM, so this compares against the emulated machine's real size there.)  Comparing
; it with what we just measured catches a whole bank having gone missing.  The
; stock IPL rewrites this value on every boot, so the mismatch only shows on
; the first boot after the fault appears.  Returns 2 (skip) when SRAM holds
; nothing plausible, so an unconfigured machine is not reported as broken.
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
; is flat and the contents have been lost, not that the chip is bad; the stock
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
; Timer B is stopped, so its data register behaves as a scratch register.
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
; The CRTC register file is write-only on real silicon: R00/R04 read back
; $0000 on a real PRO while the screen is plainly being scanned.  So no
; readback test of the CRTC can work, and the one that used to live here
; only ever passed because MAME implements those registers as readable.
;
; Ask the MFP instead.  The CRTC drives V-DISP into GPIP bit 4 and H-SYNC into
; bit 7, so if either of those toggles the CRTC is generating timing -- that is
; externally visible proof, and it needs nothing to read back.
;
; Sample the port hard, accumulating OR and AND.  A bit set in OR and clear in
; AND changed during the window.  An undriven bus reads all-ones constantly,
; so it cancels out and correctly reports dead rather than masquerading as
; live data, which is exactly how the old readback tests were fooled.
;
; GPIP bit 6 is the CRTC raster interrupt.  It only toggles once a raster line
; has been programmed, so it is deliberately not in the mask -- a healthy
; machine that never set one would otherwise fail.  For the same reason the
; verdict needs only one of the two signals, not both.
;
; The loop exits as soon as both bits have moved, which is a little over one
; frame on a healthy machine; the counter only bounds the dead case.  V-DISP
; toggles once per frame (~18 ms), H-SYNC once per scanline, so the window has
; to be able to span a frame: 40000 iterations is ~200 ms on a 10 MHz 68000
; and still ~60 ms on a 25 MHz 68030.
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

;--- MIDI board --------------------------------------------------------------
; Sharp's CZ-6BM1 is the board this was written against, but it is not the only
; one: third-party cards put the same YM3802 at the same addresses, so the test
; works on those too and the report line says only "MIDI" rather than naming a
; board it cannot actually identify.
;
; Optional expansion card, so this is a run_test_opt: an empty slot answers no
; bus cycle at all and reads SKIP, exactly as SCSI does on a PRO.
;
; Presence alone is not proof the board works, and a floating bus reads $FF on
; everything, so this asks the YM3802 to prove itself: every write to the chip
; latches the byte into its write-data register, and register 3 reads that
; latch back.  Two different patterns rule out a bus stuck high or low.
;
; Register 0 is the write target because it has no side effects -- writing
; register 1 would reload the register-group select and can reset the device.
;
; CAVEAT: the latch behaviour is modelled on MAME's YM3802 and is not verified
; against a real CZ-6BM1.  A board that is plainly fitted but reports FAIL here
; means the latch, not the board, is what to doubt first.
test_midi:
                movem.l d1/a0,-(sp)
                lea     MIDI,a0
                tst.b   1(a0)                   ; bus-errors out if no card
                move.b  #$5A,1(a0)
                nop
                move.b  MIDI_WDR,d1
                cmp.b   #$5A,d1
                bne.s   .bad
                move.b  #$A5,1(a0)
                nop
                move.b  MIDI_WDR,d1
                cmp.b   #$A5,d1
                bne.s   .bad
                moveq   #0,d0
                bra.s   .out
.bad:           moveq   #1,d0
.out:           movem.l (sp)+,d1/a0
                rts

;--- RP5C15 RTC: is the chip there and does its bus work? --------------------
; Bank 1 holds the alarm registers, which are plain storage and do not depend on
; the oscillator at all.  Select bank 1, write $5 then $A to alarm register 2
; and read each back.  That proves the register file and the bus to the chip,
; and nothing else -- whether the clock actually runs is test_rtcosc's problem.
;
; This used to check that the seconds and minutes registers held legal BCD,
; which says almost nothing: a clock frozen at a plausible time passes it, and
; it cannot tell a chip that is not answering from one holding bad data.  It
; only caught the fault on a real PRO because the registers there happened to
; read $F, which is not a legal digit.
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
; The 32.768 kHz crystal and the battery corrosion around it are the classic
; X68000 failure, and nothing above would notice: the registers keep whatever
; they were left holding.  So read the seconds, wait, and read them again.
;
; The timer-enable bit is set first.  A clock that is merely switched off is a
; different thing from a dead oscillator, and only the second is worth
; reporting -- MAME comes up with the bit clear, which is why the diagnostic
; page used to show the time never moving under emulation.
;
; Timed off V-DISP rather than delay_seconds.  delay_seconds is calibrated for
; a 10 MHz 68000 and runs several times faster on an X68030, which made its
; "one second" far too short to see the clock move and failed this test on a
; perfectly good machine.  Video frames are ~55 Hz whatever the CPU is doing,
; so counting them measures real time.  If the CRTC is not scanning there are
; no frames to count and it falls back to delay_seconds -- a machine in that
; state has already failed the video timing test a line earlier.
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

; wait_frames: d0 = frames to wait for, out d0 = 0 if the video timing never
; moved and the wait was therefore not real time.  Each step is bounded so a
; CRTC that is not scanning cannot hang the POST.
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

; sprite_init: put the sprite/BG controller into the state MTEST reaches it in.
;
; The four timing registers get the values and order a stock IPL writes, tapped
; from a live boot -- they read back $FF, so the state after boot does not tell
; you what was programmed.  The control register gets $0000, which is what
; MTEST writes, not the $0010 the IPL leaves behind.
;
; That distinction is the whole point.  Writing $0010 with the timing registers
; set still failed on a real PRO, and so did writing $0000 without them; MTEST
; does both and works, on the same machine.  Bit 4 of the control register
; looks like a BG enable, and a controller that is fetching from its own RAM is
; not going to let the CPU in.
;
; The stock IPL never touches sprite RAM at all during boot, so there was no
; enabling sequence of its own to copy -- only MTEST's.
sprite_init:
                move.w  #$00FF,SPR_HDISP
                move.w  #$00FF,SPR_HTOTAL
                move.w  #$00FF,SPR_VDISP
                move.w  #$00FF,SPR_RES
                move.w  #$0000,SPRREG           ; all BG planes off
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

;--- HD63450 DMAC ------------------------------------------------------------
; Channel 0 is idle at reset, so its memory address register reads back what
; we write, proving the device is decoded and alive.
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
; Removed.  The only readable register drives a couple of bits and leaves the
; rest open, so on real hardware this read returns bus float: a healthy PRO
; gave $FF on one boot and $C0 on the next.  The old test called $FF "absent",
; which made it a coin toss rather than a test.  Proving this chip alive means
; commanding it and observing a state change, which is more than a POST can do
; between reset and handing over.

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
test_sprram:
                movem.l d1-d2/a0,-(sp)
; Sprite RAM is not reachable in every screen mode, and video_init picks one of
; the modes where it is not.  IOCS says so itself: _SP_INIT ($FFC418 in the
; Compact IPL) opens with a guard that reads CRTC R20, masks the low byte, and
; refuses to touch sprite hardware at all when it is $16 -- which is exactly
; what video_init writes ($0B16, the 768-wide high-resolution mode).
;
; Confirmed on a real PRO: a single word read of $EB8000 bus-errors at $0B16
; and returns data at $0B15, $0B11, $0B10, $0B05, $0B01 and $0B00.  So switch
; to $0B15 for the test.  The display is garbled while this runs, because the
; rest of the CRTC timing still describes the old mode; R20 goes back at the
; dispatch site, which is the only place that survives a bus error.
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

;--- CRTC --------------------------------------------------------------------
; Removed.  The register file does not read back on real silicon: a PRO with a
; visibly correct 768x512 display returns $0000 from R00, R04 and R20 alike.
; MAME implements those registers as readable, which is the only reason the
; old read-back test ever passed.  The screen carrying this report is already
; better evidence that the CRTC is programmed and scanning than any register
; comparison could be.

;=============================================================================
; video
;=============================================================================
; Register values are the ones the stock IPL programs for CRTMOD 16
; (768x512, 96x32 text), read back from a live boot of the stock ROM.
; wait_scanning: block until the CRTC is really scanning, or give up trying.
;
; Watches V-DISP on the MFP GPIP go high then low a few times, which is a frame
; each.  Bounded at every step: a CRTC that never scans must not hang the POST,
; and test_vidtiming reports that case properly a few lines later.
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

video_init:
                movem.l d0/a0-a1,-(sp)
; Monitor contrast is zero out of reset and the display stays blank until it is
; set -- the stock IPL loads it from SRAM at $FF00D4, long after we run.  Wind
; it to maximum: this is a diagnostic screen and should be readable whatever
; the user's saved preference is.  The stock IPL restores their setting when we
; hand over.
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

;--- putchar: d0 = char, d1 = colour, cursor in w_col / w_row ----------------
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
                clr.w   w_col
                addq.w  #1,w_row
                cmp.w   #SCR_ROWS,w_row
                blt.s   .ok
                bsr     scroll_up
                move.w  #SCR_ROWS-1,w_row
.ok:            rts

; scroll_up: shift both text planes up one row and blank the last one.  Without
; it, everything past the bottom of the screen landed on the final line and
; overwrote itself, which is what the diagnostic page did once it grew past 32
; rows.  Only runs on overflow, and copies about 124K, so it costs nothing on a
; report that fits.
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

;--- print_str: a0 = asciiz, d1 = colour -------------------------------------
print_str:
                movem.l d0/a0,-(sp)
.loop:          moveq   #0,d0
                move.b  (a0)+,d0
                beq.s   .done
                bsr     putchar
                bra.s   .loop
.done:          movem.l (sp)+,d0/a0
                rts

;--- print_dec: d0 = unsigned value (<= 65535), d1 = colour ------------------
; Echoes to the serial port as well.
print_dec:
                movem.l d0-d3/a0,-(sp)
                and.l   #$FFFF,d0
                lea     w_buf+12,a0
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

;=============================================================================
; test dispatch
;=============================================================================
; run_test / run_test_opt: a0 = test name, a1 = test routine.
;
; Prints the name, establishes bus-error recovery around the call, runs the
; test and prints the verdict.  Without the recovery, probing a device that is
; not fitted on this model bus-errors into fault_handler, which would jump
; through whatever a3 happened to hold.
;
; A bus error means nothing responded at that address at all.  run_test calls
; that a failure; run_test_opt calls it SKIP, which is what you want for
; hardware that is genuinely optional -- a controller that is fitted but broken
; still answers the bus cycle and fails on its data instead.
run_test:
                moveq   #5,d2                   ; verdict if the probe faults
                bra.s   run_test_common
run_test_opt:
                moveq   #2,d2                   ; SKIP if the probe faults
run_test_common:
                movem.l d1-d2/a0-a4,-(sp)
; The fault verdict cannot live in a register.  fault_handler unwinds the stack
; and jumps straight to .fault, so the test's own movem restore never runs and
; whatever it left in d2 survives.  test_sprram used d2 to stash VC R2, so a
; sprite RAM bus error -- which should read SKIP -- arrived at .fault as $0020
; and printed FAIL instead.  Anything a test cannot reach is safe; a work word
; is.
                move.w  d2,w_fverdict
                clr.w   w_fdetail
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

; verdict: d0 = 0 pass, 2 skip, anything else fail.  Only a fail is counted.
verdict:
                movem.l d0-d1/a0,-(sp)
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
                bsr     newline
                bsr     serial_crlf
                tst.w   w_fdetail
                bne.s   .detail
                movem.l (sp)+,d0-d1/a0
                rts
.detail:
; Indented continuation under the FAIL, one of
;   $00123456 exp $5A5AA5A5 got $5A5AA5A4
;   $00100000 stuck bits $00000040
                cmp.w   #2,w_fdetail
                beq.s   .stuck
                clr.w   w_fdetail
                lea     s_indent,a0
                bsr     diag_str
                move.l  w_faddr,d0
                moveq   #8,d2
                bsr     print_hexdollar
                lea     s_exp,a0
                bsr     diag_str
                move.l  w_fexp,d0
                moveq   #8,d2
                bsr     print_hexdollar
                lea     s_got,a0
                bsr     diag_str
                move.l  w_fgot,d0
                moveq   #8,d2
                bsr     print_hexdollar
                bra.s   .detail_end
.stuck:
                clr.w   w_fdetail
                lea     s_indent,a0
                bsr     diag_str
                move.l  w_faddr,d0
                moveq   #8,d2
                bsr     print_hexdollar
                lea     s_stuck,a0
                bsr     diag_str
                move.l  w_fgot,d0
                moveq   #8,d2
                bsr     print_hexdollar
.detail_end:
                bsr     newline
                bsr     serial_crlf
                movem.l (sp)+,d0-d1/a0
                rts

; print_ramsize: writes the detected size, e.g. 4096K, where a verdict would
; go.  Called from verdict for the size line, so the line is already started.
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
; NOTE: MAME's x68000 driver wires SCC channel B to the mouse and leaves
; channel A's TxD unconnected, so this path cannot be observed under emulation.
; It is checked there by watching writes to $E98007 instead.
; SCC PCLK is 5MHz; time constant = PCLK / (2 * baud * 16) - 2.
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

; serial_char: d0 = byte.  Bounded wait, so a dead SCC cannot hang the POST.
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

; serial_drain: wait until the transmitter has actually shifted the last byte
; onto the wire, not merely accepted it.
;
; serial_char waits for "tx buffer empty" (RR0 bit 2) before writing, which
; frees the holding register while the byte before it is still in the shift
; register.  So when the final character returns there are up to two still in
; flight.  Standalone that is harmless -- the CPU parks in STOP and they drain
; on their own -- but the injected build jumps straight to the IPL, which
; resets the SCC and cuts them off mid-transmission.  On real hardware that
; lost the tail of the last line; the serial log ended "...to the IP".
;
; RR1 bit 0 is All Sent.  The SCC's register pointer auto-clears after each
; access, so register 1 has to be re-selected on every poll.  Bounded like
; every other wait here: a dead SCC must not hold the machine off the IPL.
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

;=============================================================================
; delay_seconds: d0 = seconds
;=============================================================================
; Calibrated for a 10MHz 68000; a 16MHz XVI Compact runs it about 1.6x faster.
; Nothing sets up the MFP USART any more, so the keypress shortcut this used to
; have could never fire and has been removed.
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


;--- print_hexdollar: d0 = value, d2 = digits.  Prints "$xxxxxxxx". ---------
print_hexdollar:
                movem.l d0/a0,-(sp)
                lea     s_dollar,a0
                bsr     diag_str
                movem.l (sp)+,d0/a0
                bra     print_hex

;--- print_hex: d0 = value, d2 = digit count.  Screen and serial. -----------
print_hex:
                movem.l d0-d4/a0,-(sp)
                lea     w_buf+12,a0
                clr.b   -(a0)
                move.l  d2,d4
                subq.l  #1,d4
.loop:          move.l  d0,d3
                and.l   #$0F,d3
                add.b   #'0',d3
                cmp.b   #'9',d3
                bls.s   .digit
                addq.b  #7,d3                   ; '9'+1.. -> 'A'..'F'
.digit:         move.b  d3,-(a0)
                lsr.l   #4,d0
                dbra    d4,.loop
                bsr     diag_str
                movem.l (sp)+,d0-d4/a0
                rts

;--- diag_str: a0 = asciiz, to screen and serial ----------------------------
diag_str:
                movem.l d1/a0,-(sp)
                moveq   #COL_NORMAL,d1
                bsr     print_str
                bsr     serial_str
                movem.l (sp)+,d1/a0
                rts

diag_eol:
                bsr     newline
                bsr     serial_crlf
                rts

;=============================================================================
; diagnostics -- DIAG builds only
;=============================================================================
; v2, written against what a real X68000 PRO actually reported:
;
;   CRTC R00/R04 read back $0000, not the written values and not floating
;   high, while the screen is plainly being scanned -- the register file is
;   write-only on real silicon and MAME's readable implementation is wrong.
;   So this version stops reading CRTC registers and watches the MFP GPIP
;   video timing inputs instead, which is the only externally visible proof
;   that the CRTC is running.
;
;   RTC mode register reads $F8: the low nibble is the real 4-bit register
;   ($8 = timer enabled, bank 0 already selected) and the high nibble is the
;   undriven half of the bus floating high.  So the chip answers, but the time
;   registers read $7/$F and never advance.  This version dumps the whole
;   bank, then writes and reads back a bank 1 register: if that holds, the
;   device and its bus are fine and the fault is the oscillator alone.
;
;   Probing sprite RAM hung the machine outright.  v1 called it from outside
;   run_test, so a3/a4 were never set and fault_handler jumped through a stale
;   pointer.  Every probe here goes through diag_try, which installs the same
;   recovery run_test uses and prints BUSERR instead of locking up.
;
; Nothing needs to leave the machine tidy: the stock IPL issues RESET and
; reprograms every device before it boots.
                ifd     DIAG

SPRCTL          equ     $EB0800         ; BG scroll registers

diag_section:
                movem.l d0-d7/a0-a4,-(sp)
                lea     s_diag,a0
                bsr     diag_str
                bsr     diag_eol
                bsr     diag_eol

;--- canaries: prove the fault recovery itself works ------------------------
; The first MUST print BUSERR, on real hardware and under MAME alike: a word
; read from an odd address is an address error, which the 68000 raises from the
; CPU itself before any bus cycle, and fault_handler catches it on the same
; vector path as a bus error.  If this line prints a value, recovery is not
; working; if the report stops here, it is broken outright and nothing below
; can be trusted.
                lea     d_canary1,a0
                lea     $EC0001,a2              ; odd -> address error
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

; The second is informational.  $EC0000 is the user I/O area, unpopulated on a
; stock machine, so a machine with a working bus timeout reads BUSERR.  MAME
; maps it and returns 0000, so a value here is not in itself a fault -- it just
; says a BUSERR further down means "nothing answered" rather than "timed out".
                lea     d_canary2,a0
                lea     $EC0000,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

;--- is the CRTC scanning? ---------------------------------------------------
; The CRTC register file does not read back, so ask the MFP instead: its GPIP
; inputs carry V-DISP and H-SYNC.  Sample the port hard for a fraction of a
; second and report which bits moved.  Printed as OR:AND -- a bit set in OR and
; clear in AND toggled during the sample, which is what a running CRTC looks
; like.  If OR and AND are equal, nothing moved and the video timing is dead.
                lea     d_gpip,a0
                bsr     line_start
                bsr     diag_gpip
                moveq   #4,d2
                bsr     print_hex
                bsr     diag_eol

                lea     d_gptog,a0
                bsr     line_start
                bsr     diag_gpip
                move.l  d0,d1
                lsr.l   #8,d1                   ; OR
                not.l   d0
                and.l   d1,d0                   ; OR & ~AND = bits that moved
                and.l   #$FF,d0
                moveq   #2,d2
                bsr     print_hex
                bsr     diag_eol

;--- CRTC registers, for the record -----------------------------------------
; Confirm the write-only behaviour is uniform rather than specific to R00/R04.
                lea     d_crtc0,a0
                lea     CRTC+0,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

                lea     d_crtc4,a0
                lea     CRTC+8,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

                lea     d_crtc20,a0
                lea     CRTC+$28,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

                lea     d_vcr2,a0
                lea     VC_R2,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

;--- ADPCM, which now passes ------------------------------------------------
                lea     d_adpcm,a0
                lea     ADPCM+1,a2
                lea     p_rb,a1
                moveq   #2,d2
                bsr     diag_line

;--- RTC: dump the whole time bank ------------------------------------------
; Registers 0..7 are seconds, minutes, hours and day-of-week, two BCD nibbles
; each, low nibble only.  Printed as eight nibbles, register 7 first.
                lea     d_rtcbank,a0
                bsr     line_start
                bsr     diag_rtc_dump
                moveq   #8,d2
                bsr     print_hex
                bsr     diag_eol

                lea     d_rtcmode,a0
                lea     RTC_MODE,a2
                lea     p_rb,a1
                moveq   #2,d2
                bsr     diag_line

;--- RTC: can a register be written and read back? --------------------------
; Bank 1 holds the alarm registers, which are plain storage and do not depend
; on the oscillator at all.  Select bank 1, write $5 then $A to alarm register
; 2, and read each back.  Printed as the two readbacks: 5A means the register
; file and the bus to the chip are both sound, and the fault is the clock
; itself.  FF or 77 means the chip is not really answering.
                lea     d_rtcwr,a0
                bsr     line_start
                move.b  RTC_MODE,d0
                and.b   #$0C,d0
                or.b    #$01,d0                 ; bank 1, keep alarm/timer bits
                move.b  d0,RTC_MODE
                nop
                move.b  #$05,RTC+1+2*2
                nop
                move.b  RTC+1+2*2,d1
                and.l   #$0F,d1
                lsl.l   #4,d1
                move.b  #$0A,RTC+1+2*2
                nop
                move.b  RTC+1+2*2,d0
                and.l   #$0F,d0
                or.l    d1,d0
                move.l  d0,d6                   ; stash before restoring bank
                move.b  RTC_MODE,d0
                and.b   #$0C,d0                 ; back to bank 0
                move.b  d0,RTC_MODE
                nop
                move.l  d6,d0
                moveq   #2,d2
                bsr     print_hex
                bsr     diag_eol

;--- RTC: does it advance? --------------------------------------------------
; MAME's RP5C15 does tick, but only while the mode register's timer-enable bit
; is set, and it comes up clear -- which is why this line used to show the time
; standing still under emulation and was wrongly written up as "MAME never
; ticks it".  test_rtcosc sets the bit before looking; this diagnostic page
; deliberately does not, so it shows the chip exactly as the machine left it.
; On real hardware an unchanged value means the oscillator is stopped.
                lea     d_rtctick,a0
                bsr     line_start
                bsr     diag_rtc_dump
                moveq   #8,d2
                bsr     print_hex
                lea     s_arrow,a0
                bsr     diag_str
                moveq   #8,d0
                bsr     diag_delay
                bsr     diag_rtc_dump
                moveq   #8,d2
                bsr     print_hex
                bsr     diag_eol

;--- sprite: find where the bus stops answering -----------------------------
; Probed in address order, read-only first, so the report shows exactly which
; part of the sprite controller responds.  BUSERR here is the finding: it means
; nothing drove DTACK, which is also what made the production Sprite RAM test
; report FAIL rather than a wrong value.
                lea     d_spctl,a0
                lea     SPRCTL,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

                lea     d_spreg,a0
                lea     $EB0000,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

                lea     d_sprd,a0
                lea     SPRRAM,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

;--- sprite: the same probes again, after sprite_init ------------------------
; This is the pair that matters.  The production test programs the controller
; the way MTEST leaves it -- the IPL's timing values, then $EB0808 = $0000 --
; and on a real PRO it still reports FAIL.  So: probe once cold, run
; sprite_init, probe again.  If the "after" lines still say BUSERR then the
; controller is not the gate and the fault is elsewhere; if they return data
; then sprite_init works and the production test is failing on the pattern
; rather than on access, which is a completely different problem.
                bsr     sprite_init
                nop

                lea     d_sprd2,a0
                lea     SPRRAM,a2
                lea     p_rw,a1
                moveq   #4,d2
                bsr     diag_line

                lea     d_spwr2,a0
                bsr     line_start
                move.l  #$A5A55A5A,d5
                lea     SPRRAM,a2
                lea     p_wl,a1
                bsr     diag_try
                moveq   #8,d2
                bsr     diag_val
                bsr     diag_eol

;--- sprite: now with the plane enabled -------------------------------------
; video_init writes $0020 to VC R2 for text only, so bit 5 is text and bit 6 is
; the sprite/BG plane.  $EB0808 is the BG control register.  Both writes are
; themselves guarded: on a controller that is not answering, the write is what
; hangs.  VC R2 goes back to text-only before anything is printed so garbage
; PCG cannot cover the report.
                lea     d_spwctl,a0
                bsr     line_start
                move.w  #$000F,d5
                lea     SPRREG,a2
                lea     p_ww,a1
                bsr     diag_try
                move.w  #$0060,VC_R2
                nop
                moveq   #4,d2
                bsr     diag_val
                bsr     diag_eol

                lea     d_spwr,a0
                bsr     line_start
                move.l  #$A5A55A5A,d5
                lea     SPRRAM,a2
                lea     p_wl,a1
                bsr     diag_try
                move.l  d4,d6                   ; stash the write's verdict
                lea     SPRRAM,a2
                lea     p_rl,a1
                bsr     diag_try
                or.l    d6,d4                   ; BUSERR if either faulted
                move.w  #$0020,VC_R2            ; text only again, before printing
                nop
                moveq   #8,d2
                bsr     diag_val
                bsr     diag_eol

;--- main RAM: what exactly stalls? ---------------------------------------------
; A real PRO hangs in the first sustained write burst of test_dram, at $400, on
; a cold boot only, while isolated writes to the same memory during sizing work
; fine.  The CPU is waiting on a DTACK that never arrives -- a bus error would
; have been caught and reported, and nothing can guard against a cycle that
; simply never finishes.
;
; So the diagnosis has to come from which line is left without a result.  These
; are ordered least to most likely to hang, so everything before the stall is
; still information:
;
;   read stalls        -> reads are affected too, not just writes
;   slow fill stalls   -> not about rate, the location itself is bad
;   $100000 stalls     -> bursts anywhere are the problem, not low memory
;   only $400 stalls   -> specific to memory nothing had touched until then
; What actually accumulates during RAM writes?
;
; Chunking did not help: with 512-longword slices and a display update between
; them, a real PRO still stalls on the fourth slice, about 1536 longwords in.
; So it is not the length of any single burst.  Two things are left untested --
; whether it is a rate limit, and whether reads reset whatever builds up.
;
; Ordered least to most likely to stall, so everything above a hang still
; counts.  The last line is the known-bad control.
                lea     d_paced,a0
                lea     $000400,a2
                lea     p_paced,a1
                moveq   #2,d2
                bsr     diag_line

                lea     d_mixed,a0
                lea     $000400,a2
                lea     p_mixed,a1
                moveq   #2,d2
                bsr     diag_line

                lea     d_plain,a0
                lea     $000400,a2
                lea     p_plain,a1
                moveq   #2,d2
                bsr     diag_line

;--- MIDI board -------------------------------------------------------------
; The production test trusts the YM3802 write-data latch, which is modelled on
; MAME and unverified on real silicon.  These two lines are what settles that:
; if the raw read answers but the latch line does not come back $5AA5, the
; latch is the thing that is wrong, not the board.
                lea     d_midiraw,a0
                lea     p_rb,a1
                lea     MIDI+1,a2
                moveq   #2,d2
                bsr     diag_line

                lea     d_midiwdr,a0
                lea     p_midi_wdr,a1
                lea     MIDI+1,a2
                moveq   #4,d2
                bsr     diag_line

                bsr     diag_eol
                lea     s_diagend,a0
                bsr     diag_str
                bsr     diag_eol
                moveq   #20,d0
                bsr     delay_seconds
                movem.l (sp)+,d0-d7/a0-a4
                rts

;=============================================================================
; diagnostic plumbing
;=============================================================================
;--- diag_line: a0 = name, a1 = probe, a2 = address, d2 = digits ------------
diag_line:
                bsr     line_start
                bsr     diag_try
                bsr     diag_val
                bsr     diag_eol
                rts

;--- diag_try: a1 = probe, a2 = address, d5 = value for the write probes -----
; out: d0 = result, d4 = 0 completed / 1 bus error.  Installs the same recovery
; run_test uses; without it a probe that nothing answers takes the machine down.
diag_try:
                movem.l a3-a4,-(sp)
                moveq   #0,d4
                lea     .fault,a3
                move.l  a7,a4
                jsr     (a1)
                bra.s   .done
.fault:
                moveq   #1,d4
                moveq   #0,d0
.done:
                movem.l (sp)+,a3-a4
                rts

;--- diag_val: print d0 as d2 hex digits, or BUSERR if d4 is set ------------
diag_val:
                tst.l   d4
                bne.s   .err
                bra     print_hex
.err:           lea     s_buserr,a0
                bra     diag_str

;--- probes: a2 = address, d5 = value to write ------------------------------
p_rb:           moveq   #0,d0
                move.b  (a2),d0
                rts
p_rw:           moveq   #0,d0
                move.w  (a2),d0
                rts
p_rl:           move.l  (a2),d0
                rts
p_ww:           move.w  d5,(a2)
                moveq   #0,d0
                move.w  (a2),d0
                rts
p_wl:           move.l  d5,(a2)
                move.l  (a2),d0
                rts
; Write two different bytes to YM3802 register 0 and read each back out of the
; write-data latch at register 3.  Healthy board: $5AA5.  Floating bus: $FFFF.
; Register 0 is the write target because it has no side effects.
; 8K of RAM, three ways.  a2 = base.
p_fill8k:       movem.l d1/a0,-(sp)
                move.l  a2,a0
                move.l  #$800,d1
                bsr     mem_fill
                movem.l (sp)+,d1/a0
                moveq   #0,d0
                rts

; d5 = how many longwords to write, a2 = where.  dbra counts in words, which is
; ample for the range being bisected.
; 4096 longwords in eight runs of 512, with a whole video frame of idle between
; runs.  If this completes where a straight 2048 hangs, the limit is a rate and
; the cure is pacing.
p_paced:        movem.l d1-d3/a0,-(sp)
                move.l  a2,a0
                moveq   #7,d3
.chunk:
                move.w  #511,d1
.wr:            move.l  a0,d0
                move.l  d0,(a0)+
                dbra    d1,.wr
                moveq   #1,d0
                bsr     wait_frames
                dbra    d3,.chunk
                movem.l (sp)+,d1-d3/a0
                moveq   #0,d0
                rts

; 2048 longwords, reading each one back immediately after writing it.  If this
; completes, a read resets whatever the writes build up.
p_mixed:        movem.l d1-d2/a0,-(sp)
                move.l  a2,a0
                move.w  #2047,d1
.loop:          move.l  a0,d0
                move.l  d0,(a0)
                move.l  (a0)+,d2
                dbra    d1,.loop
                movem.l (sp)+,d1-d2/a0
                moveq   #0,d0
                rts

; 2048 straight writes -- the case known to hang, kept as the control.
p_plain:        movem.l d1/a0,-(sp)
                move.l  a2,a0
                move.w  #2047,d1
.loop:          move.l  a0,d0
                move.l  d0,(a0)+
                dbra    d1,.loop
                movem.l (sp)+,d1/a0
                moveq   #0,d0
                rts

; d5 = the R20 value to try, a2 = the address to read.  R20 is restored by the
; caller, because a faulting read never comes back here.
p_sprmode:      movem.l d1,-(sp)
                move.w  d5,CRTC+$28
                nop
                nop
                moveq   #0,d0
                move.w  (a2),d0
                movem.l (sp)+,d1
                rts

p_wrn:          movem.l d1/a0,-(sp)
                move.l  a2,a0
                move.w  d5,d1
                subq.w  #1,d1
.loop:          move.l  a0,d0
                move.l  d0,(a0)+
                dbra    d1,.loop
                movem.l (sp)+,d1/a0
                moveq   #0,d0
                rts

; Read the block through first, then write it.  Reads of this same range
; complete, and a read refreshes the DRAM row it touches -- so if the array
; simply has not been primed since power-on, this is the probe that says so.
p_readwrite:    movem.l d1/a0,-(sp)
                move.l  a2,a0
                move.w  #$7FF,d1
                moveq   #0,d0
.rloop:         add.l   (a0)+,d0
                dbra    d1,.rloop
                move.l  a2,a0
                move.w  #$7FF,d1
.wloop:         move.l  a0,d0
                move.l  d0,(a0)+
                dbra    d1,.wloop
                movem.l (sp)+,d1/a0
                moveq   #0,d0
                rts

; Wait a couple of seconds and then write, in case it is elapsed time rather
; than any particular access that the array needs.
p_delaywrite:   movem.l d1/a0,-(sp)
                moveq   #120,d0
                bsr     wait_frames
                move.l  a2,a0
                move.w  #$7FF,d1
.wloop:         move.l  a0,d0
                move.l  d0,(a0)+
                dbra    d1,.wloop
                movem.l (sp)+,d1/a0
                moveq   #0,d0
                rts

; The same thing with the loop deliberately slowed, to separate a rate problem
; from a bad location.
p_slow8k:       movem.l d1/a0,-(sp)
                move.l  a2,a0
                move.w  #$7FF,d1
.loop:          move.l  a0,d0
                move.l  d0,(a0)+
                nop
                nop
                nop
                nop
                dbra    d1,.loop
                movem.l (sp)+,d1/a0
                moveq   #0,d0
                rts

; Read-only sweep, in case it is not writes at all.
p_read8k:       movem.l d1/a0,-(sp)
                move.l  a2,a0
                move.w  #$7FF,d1
                moveq   #0,d0
.loop:          add.l   (a0)+,d0
                dbra    d1,.loop
                movem.l (sp)+,d1/a0
                rts

p_midi_wdr:     move.b  #$5A,MIDI+1
                nop
                moveq   #0,d0
                move.b  MIDI_WDR,d0
                lsl.w   #8,d0
                move.b  #$A5,MIDI+1
                nop
                or.b    MIDI_WDR,d0
                rts

;--- diag_gpip: hammer the MFP GPIP, out d0 = (OR << 8) | AND ---------------
; Bits that are set in OR and clear in AND changed during the sample window.
diag_gpip:
                movem.l d1-d3,-(sp)
                moveq   #0,d1                   ; OR accumulator
                moveq   #-1,d2                  ; AND accumulator
                move.l  #200000,d3
.loop:          moveq   #0,d0
                move.b  MFP_GPIP,d0
                or.l    d0,d1
                and.l   d0,d2
                subq.l  #1,d3
                bne.s   .loop
                and.l   #$FF,d1
                lsl.l   #8,d1
                and.l   #$FF,d2
                or.l    d2,d1
                move.l  d1,d0
                movem.l (sp)+,d1-d3
                rts

;--- diag_rtc_dump: out d0 = RTC registers 7..0, low nibble of each ---------
diag_rtc_dump:
                movem.l d1-d2,-(sp)
                moveq   #0,d0
                moveq   #7,d2
                lea     RTC+1+7*2,a0
.loop:          lsl.l   #4,d0
                moveq   #0,d1
                move.b  (a0),d1
                and.l   #$0F,d1
                or.l    d1,d0
                lea     -2(a0),a0
                dbra    d2,.loop
                movem.l (sp)+,d1-d2
                rts

;--- diag_delay: d0 = rough seconds, with no keypress escape ----------------
; delay_seconds returns the moment the MFP has a byte latched, which under MAME
; is immediately, making the before/after RTC pair meaningless.
diag_delay:
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

                even
s_diag:         dc.b    'DIAGNOSTICS v2  (raw values)',0
s_diagend:      dc.b    'END OF DIAGNOSTICS',0
s_arrow:        dc.b    ' -> ',0
s_buserr:       dc.b    'BUSERR',0
d_canary1:      dc.b    'ADDRERR canary (must fail)',0
d_canary2:      dc.b    'BUSERR canary $EC0000',0
d_gpip:         dc.b    'MFP GPIP or:and',0
d_gptog:        dc.b    'MFP GPIP bits moving',0
d_crtc0:        dc.b    'CRTC R00 raw',0
d_crtc4:        dc.b    'CRTC R04 raw',0
d_crtc20:       dc.b    'CRTC R20 raw',0
d_vcr2:         dc.b    'VC R2 raw',0
d_adpcm:        dc.b    'ADPCM stat',0
d_rtcbank:      dc.b    'RTC regs 7..0',0
d_rtcmode:      dc.b    'RTC mode reg',0
d_rtcwr:        dc.b    'RTC bank1 wr 5 then A',0
d_rtctick:      dc.b    'RTC regs after wait',0
d_spctl:        dc.b    'SPR read $EB0800',0
d_spreg:        dc.b    'SPR read $EB0000',0
d_sprd:         dc.b    'SPR read $EB8000',0
d_spwctl:       dc.b    'SPR write $EB0808',0
d_spwr:         dc.b    'SPR write $EB8000',0
d_sprd2:        dc.b    'SPR read $EB8000 after init',0
d_spwr2:        dc.b    'SPR write $EB8000 after init',0
d_paced:        dc.b    'RAM 4096 paced by frame',0
d_mixed:        dc.b    'RAM 2048 write+read each',0
d_plain:        dc.b    'RAM 2048 straight writes',0
d_drw:          dc.b    'RAM read then write $400',0
d_ddelay:       dc.b    'RAM delay then write $400',0
d_dslow:        dc.b    'RAM slow fill $400',0
d_dhigh:        dc.b    'RAM burst fill $100000',0
d_dlow:         dc.b    'RAM burst fill $400',0
d_midiraw:      dc.b    'MIDI reg0 raw',0
d_midiwdr:      dc.b    'MIDI WDR wr 5A then A5',0

                endif

;=============================================================================
; data
;=============================================================================
                even
s_banner:       dc.b    'SHARP X68000  POST  v0.35',0
s_ok:           dc.b    'OK',0
s_fail:         dc.b    'FAIL',0
s_skip:         dc.b    'SKIP',0
s_allok:        dc.b    'ALL TESTS PASSED',0
s_failed:       dc.b    ' TEST(S) FAILED',0
s_halted:       dc.b    'POST complete -- halted.  Power off to swap ROMs',0
s_booting:      dc.b    'EXITING',0
s_kb:           dc.b    'K',0
s_indent:       dc.b    '  ',0
s_dollar:       dc.b    '$',0
s_exp:          dc.b    ' exp ',0
s_got:          dc.b    ' got ',0
s_stuck:        dc.b    ' stuck bits ',0
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
n_midi:         dc.b    'MIDI',0                ; optional: expansion card
n_ppi:          dc.b    'PPI i8255',0
n_sprram:       dc.b    'Sprite RAM',0

                even
post_end:
