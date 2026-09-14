#!/bin/sh
# Build a MAME rompath containing the POST ROM, at post/mame-roms/.
# Run this once after build.py; then point mame at it with -rompath.
#
# One image serves every model -- MAME just wants it under the filename each
# machine's BIOS expects.
set -e
cd "$(dirname "$0")"
STOCK=../x68kxvi
BUILD=${BUILD:-build}
OUT=mame-roms
rm -rf "$OUT"; mkdir -p "$OUT/tmp"

cp "$STOCK"/cgrom.dat "$STOCK"/iplrom*.dat "$STOCK"/*.bin \
   "$STOCK"/*.ic11 "$STOCK"/*.ic12 "$OUT/tmp/" 2>/dev/null || true

ROM="$BUILD/ipl_post.dat"
[ -f "$ROM" ] || { echo "no $ROM -- run build.py first" >&2; exit 1; }

# x68kxvi covers both the Compact (-bios ipl12) and the SUPER/XVI (-bios ipl11)
cp "$ROM" "$OUT/tmp/iplromco.dat"
cp "$ROM" "$OUT/tmp/iplromxv.dat"
( cd "$OUT/tmp" && zip -q -j ../x68kxvi.zip ./* )

# x68000 = the original machine, ACE, EXPERT, PRO
cp "$ROM" "$OUT/tmp/iplrom.dat"
( cd "$OUT/tmp" && zip -q -j ../x68000.zip ./* )

# x68030 also needs an scsiinrom.dat, which we do not have; stand in with the
# Compact's so MAME will start.  Our ROM never calls into it.
cp "$ROM" "$OUT/tmp/iplrom30.dat"
cp "$STOCK"/scsiinco.bin "$OUT/tmp/scsiinrom.dat"
( cd "$OUT/tmp" && zip -q -j ../x68030.zip ./* )

rm -rf "$OUT/tmp"
echo "rompath ready:  $(pwd)/$OUT"
ls -la "$OUT"
