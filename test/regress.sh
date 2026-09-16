#!/bin/sh
# Full regression for the standalone TEST-IPL ROM under MAME.
#
# Checks that a healthy machine passes at every supported RAM size, that
# injected faults are detected, and that the serial byte stream is complete.
set -e
cd "$(dirname "$0")"

# -video none still creates a window: renderer_none attaches to an osd_window
# and window_init runs unconditionally.  SDL's dummy driver stops that.
export SDL_VIDEODRIVER=dummy

STOCK=../../x68kxvi
BUILD=../build

mkrom () {  # mkrom <dir> [ipl-image]   -- ipl-image defaults to the stock IPL
  rm -rf "$1"; mkdir -p "$1/tmp"
  cp "$STOCK"/cgrom.dat "$STOCK"/iplrom*.dat "$STOCK"/*.bin \
     "$STOCK"/*.ic11 "$STOCK"/*.ic12 "$1/tmp/" 2>/dev/null || true
  [ -n "$2" ] && cp "$2" "$1/tmp/iplromco.dat"
  ( cd "$1/tmp" && zip -q -j ../x68kxvi.zip ./* )
  rm -rf "$1/tmp"
}

run () {  # run <romdir> <ram-slot> <script> <seconds>
          # RAM is a slot device in current MAME: -ram 4m, not -ramsize 4M.
  mame x68kxvi -rompath "$1" -bios ipl12 -ram "$2" -video none -sound none \
    -window -nomaximize -nothrottle \
    -seconds_to_run "$4" -autoboot_script "$3" -autoboot_delay 0 2>&1 \
    | grep -viE 'wrong|expected:|found:|warning|iplromco|average'
}

mkrom roms "$BUILD/testipl.dat"
mkrom roms_stock

# Boot the stock ROM once so SRAM is initialised.  Our ROM never writes it, so
# without this the signature check correctly reports the flat-battery case and
# the first run would differ from the rest.  No autoboot script needed: this
# only has to let Human68k write its signature to the NVRAM MAME persists.
echo "(warming up SRAM with a stock boot)"
mame x68kxvi -rompath roms_stock -bios ipl12 -ram 4m -video none -sound none \
  -window -nomaximize -nothrottle -seconds_to_run 14 >/dev/null 2>&1 || true

echo "=== healthy machine, every RAM size ==="
for sz in 1m 2m 4m 12m; do
  printf '  %-4s ' "$sz"
  run roms $sz screen.lua 40 | grep -E 'Main RAM size|PASSED|FAILED' | tr '\n' ' '
  echo
done

echo
echo "=== injected faults must be detected ==="

# CGROM is judged against CGROM_SUM, with the value printed either way.  Check
# both halves: the stock dump passes, and one flipped bit both fails and
# reports a different value.
cgline () { sed -n 's/^ *CGROM checksum\.*  *//p'; }
base_cg=$(run roms 2m screen.lua 20 | cgline)
mkrom roms_cg "$BUILD/testipl.dat"
( cd roms_cg && mkdir t && cd t && unzip -q ../x68kxvi.zip \
  && python3 -c "
import pathlib
p=pathlib.Path('cgrom.dat'); d=bytearray(p.read_bytes()); d[0x54321]^=1; p.write_bytes(d)" \
  && zip -q -j ../x68kxvi.zip ./* && cd .. && rm -rf t )
flip_cg=$(run roms_cg 2m screen.lua 20 | cgline)
printf '  CGROM stock dump      '
case "$base_cg" in
  OK*) echo "$base_cg" ;;
  *)   echo "*** FAILED: got [$base_cg], expected OK" ;;
esac
printf '  CGROM 1 bit flipped   '
case "$flip_cg" in
  FAIL*) if [ "$flip_cg" != "$base_cg" ]; then echo "detected: $flip_cg"
         else echo "*** FAILED: same value as the good dump"; fi ;;
  *)     echo "*** FAILED: got [$flip_cg], expected FAIL" ;;
esac

cp "$BUILD/testipl.dat" /tmp/ipl_bad.dat
python3 -c "
import pathlib
p=pathlib.Path('/tmp/ipl_bad.dat'); d=bytearray(p.read_bytes()); d[0x18000]^=1; p.write_bytes(d)"
mkrom roms_ipl /tmp/ipl_bad.dat
printf '  ROM 1 bit flipped     '
run roms_ipl 2m screen.lua 20 | grep -E 'ROM checksum|FAILED' | tr '\n' ' '; echo

printf '  stuck RAM bit         '
run roms 2m faulttest.lua 20 | grep -E 'Main RAM\.|Main RAM size|FAILED' | tr '\n' ' '; echo

printf '  stuck bit, boundary   '
run roms 2m faulttest.lua 20 | grep -E 'stuck bits' | tr -s ' ' | tr '\n' ' '; echo

printf '  stuck bit, in range   '
run roms 2m faultmid.lua 20 | grep -E 'exp .* got' | tr -s ' ' | tr '\n' ' '; echo

printf '  RTC not answering     '
run roms 2m rtcdead.lua 60 | grep -E 'RTC' | tr -s ' ' | tr '\n' ' '; echo

printf '  RTC frozen, legal BCD '
run roms 2m rtcfrozen.lua 60 | grep -E 'RTC' | tr -s ' ' | tr '\n' ' '; echo

printf '  frozen MFP GPIP       '
run roms 2m nogpip.lua 20 | grep -E 'video timing|FAILED' | tr '\n' ' '; echo

echo
echo "=== an optional test that faults reports SKIP, not FAIL ==="
# fault_handler unwinds straight to run_test's .fault, so the test's own movem
# restore never runs and the fault verdict cannot live in a register a test
# might be using.  Point sprite RAM at an odd address so the test is guaranteed
# to fault, and check the verdict is SKIP rather than FAIL.  (Only meaningful
# on a 68000/68010: the 68020 and up permit misaligned data accesses, so this
# check proves nothing on x68030.)
( cd .. && python3 build.py --cdefine SPRRAM=0xEB8001 --out test/build_sprfault ) >/dev/null
mkrom roms_sprfault build_sprfault/testipl.dat
printf '  faulting sprite test  '
run roms_sprfault 2m screen.lua 60 | grep -E 'Sprite RAM' | tr -s ' ' | tr '\n' ' '; echo
rm -rf roms_sprfault build_sprfault


echo
echo "=== stack headroom ==="
# Only 3840 bytes sit below the work area, and an overflow would be silent --
# it runs into text VRAM rows nothing displays.  12m has the deepest path.
printf '  12m  '
run roms 12m stack.lua 45 | grep -E 'high-water' || echo "(no reading)"

echo
echo "=== screen matches the reference report ==="
# The greps below cover about a dozen strings out of a 21-line report, so the
# rest could drift unnoticed.  Diff the whole screen instead.  The ROM checksum
# line is excluded: it is the image's own checksum and changes with every build.
if [ -d golden ]; then
  for sz in 1m 2m 4m 12m; do
    printf '  %-4s ' "$sz"
    run roms $sz screen.lua 40 | grep -v '^iplromco\|EXPECTED:\|FOUND:\|WARNING:' \
      | sed 's/^ ROM checksum\.*.*/ ROM checksum <varies>/' > /tmp/scr_$sz.txt
    sed 's/^ ROM checksum\.*.*/ ROM checksum <varies>/' golden/screen-$sz.txt > /tmp/gold_$sz.txt
    if diff -q /tmp/scr_$sz.txt /tmp/gold_$sz.txt >/dev/null; then
      echo "identical to golden"
    else
      echo "*** DIFFERS:"; diff /tmp/gold_$sz.txt /tmp/scr_$sz.txt | sed 's/^/      /'
    fi
    rm -f /tmp/scr_$sz.txt /tmp/gold_$sz.txt
  done
else
  echo "  (no golden/ -- run ./capture-golden.sh against a known-good build)"
fi

echo
echo "=== serial byte stream ==="
run roms 2m serialcap.lua 14 | tail -3

rm -rf roms_cg roms_ipl /tmp/ipl_bad.dat
