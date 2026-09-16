/*
 * text.c -- text output to the two visible text planes.
 */
#include "testipl.h"

/* putchar_at: colour is a plane mask -- the glyph row goes to plane 0 for bit 0
   and plane 1 for bit 1, and to blank for the planes it is not in, so a cell is
   always fully overwritten. */
void putchar_at(u32 ch, u32 colour)
{
    u32 glyph = ANK8X16 + ((ch & 0xFF) << 4);
    u32 p0 = TVRAM + (u32)w_row * 16 * TV_STRIDE + w_col;
    u32 p1 = p0 + TVRAM_PLANE;
    int i;

    for (i = 0; i < 16; i++) {
        u8 g = MMIO8(glyph + i);
        MMIO8(p0) = (colour & 1) ? g : 0;
        MMIO8(p1) = (colour & 2) ? g : 0;
        p0 += TV_STRIDE;
        p1 += TV_STRIDE;
    }
    w_col = w_col + 1;
}

/* scroll_up: shift both text planes up one row and blank the last one, so a
   report longer than the screen does not overwrite its own final line.  Copies
   about 124K, but only on overflow. */
static void scroll_up(void)
{
    u32 plane;
    int p;

    for (p = 0, plane = TVRAM; p < 2; p++, plane += TVRAM_PLANE) {
        u32 dst = plane;
        u32 src = plane + 16 * TV_STRIDE;
        u32 n = (SCR_ROWS - 1) * 16 * TV_STRIDE / 4;
        while (n--) {
            MMIO32(dst) = MMIO32(src);
            dst += 4;
            src += 4;
        }
        n = 16 * TV_STRIDE / 4;
        while (n--) {
            MMIO32(dst) = 0;
            dst += 4;
        }
    }
}

void newline(void)
{
    w_col = LEFT_MARGIN;
    w_row = w_row + 1;
    if (w_row >= SCR_ROWS) {
        scroll_up();
        w_row = SCR_ROWS - 1;
    }
}

void print_str(const char *s, u32 colour)
{
    while (*s)
        putchar_at((u8)*s++, colour);
}

/* hex_to_buf: builds the text backwards in the work-area scratch buffer.  No
   local array -- the stack is 3840 bytes of text VRAM and every byte counts. */
char *hex_to_buf(u32 v, int digits)
{
    u32 p = w_buf_end;

    MMIO8(p) = 0;
    while (digits-- > 0) {
        u32 d = v & 0x0F;
        p--;
        MMIO8(p) = (u8)(d < 10 ? d + '0' : d - 10 + 'A');
        v >>= 4;
    }
    return (char *)p;
}

/* print_dec: unsigned, <= 65535.  Screen and serial. */
void print_dec(u32 v, u32 colour)
{
    u32 p = w_buf_end;

    v &= 0xFFFF;
    MMIO8(p) = 0;
    do {
        p--;
        MMIO8(p) = (u8)('0' + (v % 10));
        v /= 10;
    } while (v);

    print_str((const char *)p, colour);
    serial_str((const char *)p);
}

/* detail_str: to screen and serial. */
void detail_str(const char *s)
{
    print_str(s, COL_NORMAL);
    serial_str(s);
}

/* print_hex: screen and serial. */
void print_hex(u32 v, int digits)
{
    detail_str(hex_to_buf(v, digits));
}

/* print_hex_scr: screen only, for the test_dram progress address -- once per
   8K would drown the serial log. */
void print_hex_scr(u32 v, int digits)
{
    print_str(hex_to_buf(v, digits), COL_NORMAL);
}

void print_hexdollar(u32 v, int digits)
{
    detail_str("$");
    print_hex(v, digits);
}
