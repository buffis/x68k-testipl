;-----------------------------------------------------------------------------
; crt0.s -- reset entry and everything C cannot express.
;
; Placement comes from the linker script, not from an org here.  The header
; section is listed first there, so the fixed layout build.py patches blind --
; bra.w at +0, expected ROM checksum at +4 -- lands at the start of the payload.
;
; THE RULE: a7 is only ever reloaded in assembly, at a point where no C frame
; is live.  That is why the bootstrap returns here between video_init and
; wait_scanning rather than letting C drive startup.
;-----------------------------------------------------------------------------

                xref    _video_init
                xref    _wait_scanning
                xref    _testipl_main
                xref    longjmp_core

TVRAM_RESV      equ     $E7F000
STACK_TOP       equ     $E7FF00
WORK            equ     $E7FF00
w_jbp           equ     WORK+56
w_fverdict      equ     WORK+10
AREASET         equ     $E86001
SYSPORT         equ     $E8E000
DMAC            equ     $E84000
CRTC            equ     $E80000

;=============================================================================
; header -- fixed layout, so build.py can patch the checksum without reading
; symbols out of the assembler listing.
;   +0  branch to the entry point (the reset vector points here)
;   +4  expected ROM checksum
;=============================================================================
                section header,code
                bra.w   testipl_entry
                global  _romsum_ref
_romsum_ref:    dc.l    0

                section CODE,code

;-----------------------------------------------------------------------------
; probe_stack \1 -- if off-screen text VRAM stores data, point a7 at it;
; otherwise branch to \1 with a7 untouched.  A macro, not a subroutine: the
; first use runs before there is a stack to bsr with.  Two patterns and a
; longword below the base, so a window that folds onto itself cannot pass.
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

;=============================================================================
; entry
;=============================================================================
                global  testipl_entry
testipl_entry:
                move.w  #$2700,sr               ; supervisor, interrupts off
                reset                           ; reset external devices

;--- let low memory be written -----------------------------------------------
; AREASET governs what may be written to low memory and comes up undefined at
; power-on; leave it alone and writes above $400 hang the bus on real hardware.
; MAME does not implement the register, so this cannot be verified there.
                move.b  #0,AREASET

;--- make video RAM decode predictably before anything touches it ------------
; Text VRAM is only a flat array while CRTC R21 has simultaneous-plane access
; and the access mask switched off, and R21 is undefined at power-on.  Neither
; store has dependencies, so both are safe with no stack.
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
; No guard is armed yet.  fault_handler reads this, so it must be definite
; before anything can fault -- it is decayed TVRAM noise otherwise.
                clr.l   w_jbp

; Fill ALL 256 exception vectors, not just the two we use.  Level 7 is
; non-maskable, so the move.w #$2700,sr above is no protection: an interrupt
; raised from the undefined power-on state would vector through whatever noise
; low RAM holds.  Both stock IPLs do this as their first act.
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
; it, clear its status.  Guarded with the a3/a4 idiom rather than a jmp_buf:
; this runs before any C frame exists, and fault_handler falls back to it
; whenever w_jbp is zero.
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
; idle.  Bring the display up before testing half a megabyte of it.
                jsr     _video_init

;--- get the stack out of main RAM ------------------------------------------
; The probe at entry ran before the CRTC was programmed, so on a cold machine it
; takes the fallback and leaves the stack at $2000 -- inside the region test_dram
; patterns over.  Ask again now the display is scanning.  Nothing is live on the
; stack here, so a7 can simply be reloaded -- and doing it before wait_scanning
; means that routine's frame sits in memory that has just been validated and is
; being refreshed.
                probe_stack .keep_stack
.keep_stack:
                clr.l   w_jbp                   ; the probe may have run over it

; Paint the stack region so its high-water mark can be measured.  Only 3840
; bytes sit between $E7F000 and the work area, and an overflow would run into
; text VRAM silently -- nothing reads those rows, so there would be no symptom
; until a longjmp restored a smashed frame.  test/stack.lua reads the mark.
                lea     TVRAM_RESV,a0
                move.l  #$DEADBEEF,d0
                move.w  #(STACK_TOP-TVRAM_RESV)/4-2,d1
.paint:
                move.l  d0,(a0)+
                dbra    d1,.paint

                jsr     _wait_scanning

                jsr     _testipl_main           ; never returns

;=============================================================================
; halt / hand over
;=============================================================================
; Standalone there is nothing to hand over to, so stop with the report up.
; Interrupts are masked, so STOP parks here for good; the loop is belt and
; braces against a stray NMI.
                global  _cpu_halt
_cpu_halt:
                move.w  #$2700,sr
.stopped:
                stop    #$2700
                bra.s   .stopped

                ifd     IPL_ENTRY
                global  _chain_to_ipl
_chain_to_ipl:
                move.w  #$2700,sr
                jmp     IPL_ENTRY               ; the injected IPL takes over
                endif

;=============================================================================
; handlers
;=============================================================================
; nmi_handler: level 7, which no status register can mask.  A plain rte is not
; enough -- if something has latched an NMI, rte returns straight into it and the
; machine spins in a loop that looks exactly like a stalled bus.  Writing $0C to
; the system port is what acknowledges it.
nmi_handler:
                move.b  #$0C,SYSPORT+7
                rte

; vec_ignore: anything without a real handler.  Returning is right for a
; spurious interrupt, and for a genuine fault no worse than the garbage address
; it replaces.
vec_ignore:
                rte

dead_end:
; No usable memory anywhere, so nothing can be reported.  Rattle the system port
; to make the failure at least visible on a scope.
                move.b  #$0F,SYSPORT+1
                move.b  #$00,SYSPORT+1
                bra.s   dead_end

; Bus / address error handler.  A group 0 fault cannot be resumed, so the only
; recovery is to discard the frame and leave through a guard.  If a jmp_buf is
; armed we longjmp out of it; otherwise fall back to the a3/a4 idiom, which is
; what the DMAC quiesce above uses before any C exists.
;
; The longjmp value is always 1.  Which verdict a fault produces is run_test's
; business and lives in w_fverdict, so a caller that only needs "did this fault"
; does not have to care.
fault_handler:
                move.l  w_jbp,d0
                beq.s   .no_guard
                movea.l d0,a0
                moveq   #1,d0
                jmp     longjmp_core
.no_guard:
                movea.l a4,a7
                jmp     (a3)
