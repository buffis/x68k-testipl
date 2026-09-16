/*
 * testipl.h -- shared declarations.
 *
 * Verdict protocol: a test body returns 0 pass, 2 skip, 6 "this line prints
 * the RAM size instead of a verdict", anything else fail.
 */
#ifndef TESTIPL_H
#define TESTIPL_H

#include "hw.h"

#define V_PASS   0
#define V_SKIP   2
#define V_FAIL   1
#define V_STUCK  3      /* fail, with a stuck-bit mask in w_fgot */
#define V_DEAD   4      /* fail: no low memory at all */
#define V_FAULT  5      /* fail: the probe bus-errored */
#define V_SIZE   6      /* print w_ramsize where the verdict would go */

/*--- runtime.s -------------------------------------------------------------*/
/* 13 longwords: d2-d7, a2-a6, a7, return PC. */
typedef u32 jmp_buf[13];

int  setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

u32  get_sp(void);
void nop_settle(void);
void delay_seconds(u32 secs);

/* The memory-under-test primitives stay in assembly: the exact access pattern
   is the experiment, they run over 12MB, and they record the failure detail. */
int  mem_fill  (u32 base, u32 longwords);
int  mem_verify(u32 base, u32 longwords);
void mem_clear (u32 base, u32 longwords);

/*--- video.c ---------------------------------------------------------------*/
void video_init(void);
void wait_scanning(void);
void tvram_clear(void);
int  wait_frames(u32 frames);

/*--- text.c ----------------------------------------------------------------*/
void putchar_at(u32 ch, u32 colour);
void newline(void);
void print_str(const char *s, u32 colour);
void print_dec(u32 v, u32 colour);
void print_hex_scr(u32 v, int digits);
void print_hex(u32 v, int digits);
void print_hexdollar(u32 v, int digits);
void detail_str(const char *s);
char *hex_to_buf(u32 v, int digits);

/*--- serial.c --------------------------------------------------------------*/
void serial_init(void);
void serial_char(u32 c);
void serial_str(const char *s);
void serial_crlf(void);
void serial_drain(void);

/*--- report.c --------------------------------------------------------------*/
void run_test(const char *name, int (*body)(void));
void run_test_opt(const char *name, int (*body)(void));
void line_start(const char *name);
void verdict(u32 v);
void progress_char(u32 ch);
void progress_clear(void);

/*--- dev_tests.c -----------------------------------------------------------*/
int test_mfp(void);
int test_vidtiming(void);
int test_rtc(void);
int test_rtcosc(void);
int test_dmac(void);
int test_opm(void);
int test_ppi(void);
int test_fdc(void);
int test_scsi(void);

/*--- mem_tests.c -----------------------------------------------------------*/
int test_tvram(void);
int test_cgrom(void);
int test_romsum(void);
int test_gvram(void);
int test_sprram(void);
int test_sram(void);
int test_ramsize(void);
int test_dram(void);
int test_ramsize_sram(void);
void dram_tick(void);

/*--- strings (report.c) ----------------------------------------------------*/
extern const char s_banner[];

#endif
