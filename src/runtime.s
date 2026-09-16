;-----------------------------------------------------------------------------
; runtime.s -- the parts of the C runtime this ROM has to supply itself.
;
; Nothing is linked from a library: there is no libc, and no RAM to hold one's
; state if there were.  Arguments arrive on the stack (vbcc's default ABI),
; results come back in d0, and d2-d7/a2-a6 are preserved.
;-----------------------------------------------------------------------------

WORK            equ     $E7FF00
w_fdetail       equ     WORK+16
w_faddr         equ     WORK+24
w_fexp          equ     WORK+28
w_fgot          equ     WORK+32
MEM_XOR         equ     $5A5AA5A5

                section CODE,code

;=============================================================================
; setjmp / longjmp
;=============================================================================
; jmp_buf is 13 longwords: return PC, a7, then d2-d7/a2-a6.
;
; A bus error enters the handler on a 68000 group-0 frame that cannot be
; resumed with rte, so recovery never returns -- it always comes out here.
;=============================================================================
                global  _setjmp
_setjmp:
                move.l  4(sp),a0                ; env
                move.l  (sp),(a0)               ; return PC
                move.l  a7,4(a0)                ; SP as of the call
                movem.l d2-d7/a2-a6,8(a0)
                moveq   #0,d0
                rts

                global  _longjmp
_longjmp:
                move.l  4(sp),a0                ; env
                move.l  8(sp),d0                ; value
                ; fall through

; longjmp_core: a0 = env, d0 = value.  fault_handler jumps straight here,
; because the group-0 frame under a7 is garbage that a7 is about to discard.
                global  longjmp_core
longjmp_core:
                tst.l   d0
                bne.s   .nonzero
                moveq   #1,d0                   ; longjmp(env,0) must return 1
.nonzero:
                movem.l 8(a0),d2-d7/a2-a6
                move.l  4(a0),a7
                move.l  (a0),(a7)               ; overwrite the return slot
; Normalise SR on the way out.  A fault enters the handler with whatever mask
; was live, and we never rte, so forcing it here removes a class of "worked in
; MAME" surprises.
                move.w  #$2700,sr
                rts

;=============================================================================
; small helpers
;=============================================================================
; get_sp: test_dram needs to know whether the stack fell back into main RAM,
; which it is about to pattern over.  Taking the address of a local would not
; survive the optimiser.
                global  _get_sp
_get_sp:
                move.l  a7,d0
                addq.l  #4,d0                   ; the caller's sp, not ours
                rts

; nop_settle: one nop between a device write and the read-back.  volatile
; guarantees ordering but not delay.
                global  _nop_settle
_nop_settle:
                nop
                rts

;=============================================================================
; delay_seconds: d0 = seconds
;=============================================================================
; Calibrated for a 10MHz 68000; a 16MHz XVI Compact runs it about 1.6x faster.
; Use wait_frames where real time matters -- see test_rtcosc.
                global  _delay_seconds
_delay_seconds:
                movem.l d2-d3,-(sp)
                move.l  12(sp),d2
                beq.s   .out
.second:
                move.w  #$FFFF,d0
.outer:
                move.w  #6,d3
.inner:         nop
                dbra    d3,.inner
                dbra    d0,.outer
                subq.l  #1,d2
                bne.s   .second
.out:           movem.l (sp)+,d2-d3
                rts

;=============================================================================
; generic memory fill / verify
;   int  mem_fill  (u32 base, u32 longwords)   -> always 0
;   int  mem_verify(u32 base, u32 longwords)   -> 0 pass, 1 fail
;   void mem_clear (u32 base, u32 longwords)
;
; The pattern is derived from the address, so stuck or swapped address lines
; show up as well as stuck data bits.  Chunked at $8000 longwords because dbra
; counts 16 bits and the regions are bigger than that.
;
; These stay in assembly deliberately: the exact access pattern is what
; exercises the address and data lines, and a compiler free to unroll or
; reorder would be changing the experiment rather than running it.
;=============================================================================
                global  _mem_fill
_mem_fill:
                movem.l d2-d3/a2,-(sp)
                movea.l 16(sp),a0               ; base
                move.l  20(sp),d1               ; longwords
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
                movem.l (sp)+,d2-d3/a2
                rts

                global  _mem_verify
_mem_verify:
                movem.l d2-d3/a2,-(sp)
                movea.l 16(sp),a0
                move.l  20(sp),d1
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
; Record where and how: the bits that differ name the chip to replace.
                move.l  a0,w_faddr
                move.l  d0,w_fexp
                move.l  (a0),w_fgot
                move.w  #1,w_fdetail
                moveq   #1,d0
.out:
                movem.l (sp)+,d2-d3/a2
                rts

                global  _mem_clear
_mem_clear:
                movem.l d2-d3,-(sp)
                movea.l 12(sp),a0
                move.l  16(sp),d1
                moveq   #0,d3
.chunk:
                move.l  d1,d2
                cmp.l   #$8000,d2
                bls.s   .small
                move.l  #$8000,d2
.small:
                sub.l   d2,d1
                subq.w  #1,d2
.loop:          move.l  d3,(a0)+
                dbra    d2,.loop
                tst.l   d1
                bne.s   .chunk
                movem.l (sp)+,d2-d3
                rts

;=============================================================================
; __divu / __divs -- 32-bit divide and modulo
;=============================================================================
; The 68000 has no 32/32 divide, so vbcc calls out for one.  Convention, taken
; from vbcc's own emitted code: d0 = dividend, d1 = divisor, quotient back in
; d0 and remainder in d1 (a % b is a call to the same helper, using d1).
;
; d2-d7/a2-a6 are callee-saved, so everything the loop touches is stacked.
;
; print_dec is the only division in the ROM and its values fit in 16 bits, but
; implement the general case so any future C that reaches for / or % links.
;=============================================================================
                global  __divu
__divu:
                movem.l d2-d5,-(sp)
                move.l  d0,d3                   ; dividend, becomes quotient
                moveq   #0,d5                   ; remainder
                tst.l   d1
                beq.s   .divzero                ; 0/0 rather than a trap: this
                                                ; is a diagnostic, not a kernel
                moveq   #31,d2
.loop:
                lsl.l   #1,d3                   ; MSB out into X
                roxl.l  #1,d5                   ; ...and into the remainder
                cmp.l   d5,d1                   ; d1 - d5
                bhi.s   .nosub                  ; divisor > remainder
                sub.l   d1,d5
                addq.l  #1,d3                   ; quotient bit, in the vacated LSB
.nosub:
                dbra    d2,.loop
                move.l  d3,d0
                move.l  d5,d1
                movem.l (sp)+,d2-d5
                rts
.divzero:
                moveq   #0,d0
                moveq   #0,d1
                movem.l (sp)+,d2-d5
                rts

; __divs: signed.  Divide the magnitudes, then fix the signs -- the quotient is
; negative when the operands differ in sign, and the remainder takes the sign of
; the dividend.
                global  __divs
__divs:
                movem.l d2,-(sp)
                moveq   #0,d2                   ; bit 0 negate quotient,
                                                ; bit 1 negate remainder
                tst.l   d0
                bpl.s   .dpos
                neg.l   d0
                addq.b  #3,d2                   ; dividend negative: both flip
.dpos:
                tst.l   d1
                bpl.s   .vpos
                neg.l   d1
                eor.b   #1,d2                   ; divisor negative: quotient only
.vpos:
                bsr     __divu                  ; preserves d2-d5
                btst    #0,d2
                beq.s   .qok
                neg.l   d0
.qok:
                btst    #1,d2
                beq.s   .rok
                neg.l   d1
.rok:
                movem.l (sp)+,d2
                rts
