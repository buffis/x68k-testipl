#!/bin/sh
# Capture reference output from the current build into golden/.
# The migration to C diffs against these: regress.sh only greps a dozen strings
# out of a 30-line report, so everything else would drift unnoticed.
set -e
cd "$(dirname "$0")"
export SDL_VIDEODRIVER=dummy
STOCK=../../x68kxvi
BUILD=${BUILD:-../build}
OUT=${OUT:-golden}
mkdir -p "$OUT"

mkrom () {
  rm -rf "$1"; mkdir -p "$1/tmp"
  cp "$STOCK"/cgrom.dat "$STOCK"/iplrom*.dat "$STOCK"/*.bin \
     "$STOCK"/*.ic11 "$STOCK"/*.ic12 "$1/tmp/" 2>/dev/null || true
  [ -n "$2" ] && cp "$2" "$1/tmp/iplromco.dat"
  ( cd "$1/tmp" && zip -q -j ../x68kxvi.zip ./* )
  rm -rf "$1/tmp"
}

run () {
  mame x68kxvi -rompath "$1" -bios ipl12 -ram "$2" -video none -sound none \
    -window -nomaximize -nothrottle \
    -seconds_to_run "$4" -autoboot_script "$3" -autoboot_delay 0 2>&1 \
    | grep -viE 'wrong|expected:|found:|warning|iplromco|average'
}

mkrom roms_golden "$BUILD/testipl.dat"
for sz in 1m 2m 4m 12m; do
  echo "capturing screen-$sz..."
  run roms_golden $sz screen.lua 40 > "$OUT/screen-$sz.txt"
done
echo "capturing serial-2m..."
# squeeze runs of dots: test_rtcosc's count depends on when the RTC second
# rolls over, so it is not reproducible
run roms_golden 2m serialcap.lua 14 | sed 's/\.\{2,\}/../g' > "$OUT/serial-2m.txt"
rm -rf roms_golden
echo "done -> $OUT"
