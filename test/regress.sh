#!/bin/sh
# Full regression for the standalone POST ROM under MAME.
#
#   ./regress.sh
#
# Checks that a healthy machine passes at every supported RAM size, that
# injected faults are actually detected, and that the serial byte stream is
# complete.
#
# There is no "boots identically to the stock ROM" check any more: this ROM is
# a diagnostic that halts when it is done and deliberately boots nothing.
set -e
cd "$(dirname "$0")"

# MAME's -video none still creates a window: renderer_none attaches to an
# osd_window and window_init runs unconditionally, so a real window appears and
# takes focus.  SDL's dummy video driver stops it reaching the display at all.
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

mkrom roms "$BUILD/ipl_post.dat"
mkrom roms_stock

# Boot the stock ROM once so SRAM is initialised.  Our ROM never writes it --
# it boots nothing -- so without this the signature check correctly reports the
# flat-battery case and the first run would differ from the rest.
echo "(warming up SRAM with a stock boot)"
run roms_stock 4m timing.lua 14 >/dev/null 2>&1 || true

echo "=== healthy machine, every RAM size ==="
for sz in 1m 2m 4m 12m; do
  printf '  %-4s ' "$sz"
  run roms $sz screen.lua 40 | grep -E 'Main RAM size|PASSED|FAILED' | tr '\n' ' '
  echo
done

echo
echo "=== injected faults must be detected ==="

# CGROM is reported as a value now, not judged, so the check is that the
# reported checksum actually tracks the contents.
base_cg=$(run roms 2m screen.lua 20 | grep 'CGROM checksum' | awk '{print $NF}')
mkrom roms_cg "$BUILD/ipl_post.dat"
( cd roms_cg && mkdir t && cd t && unzip -q ../x68kxvi.zip \
  && python3 -c "
import pathlib
p=pathlib.Path('cgrom.dat'); d=bytearray(p.read_bytes()); d[0x54321]^=1; p.write_bytes(d)" \
  && zip -q -j ../x68kxvi.zip ./* && cd .. && rm -rf t )
flip_cg=$(mame x68kxvi -rompath roms_cg -bios ipl12 -ram 2m -video none -sound none \
  -window -nomaximize -nothrottle -seconds_to_run 20 -autoboot_script screen.lua \
  -autoboot_delay 0 2>&1 | grep 'CGROM checksum' | awk '{print $NF}')
printf '  CGROM 1 bit flipped   '
if [ -n "$base_cg" ] && [ -n "$flip_cg" ] && [ "$base_cg" != "$flip_cg" ]; then
  echo "checksum tracked the change: $base_cg -> $flip_cg"
else
  echo "*** FAILED: $base_cg -> $flip_cg (expected them to differ)"
fi

cp "$BUILD/ipl_post.dat" /tmp/ipl_bad.dat
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
# restore never runs.  The fault verdict therefore cannot live in a register a
# test might be using -- test_sprram stashes VC R2, and when that was d2 a
# sprite RAM bus error printed FAIL instead of SKIP.  Point sprite RAM at an
# odd address so the test is guaranteed to fault, and check the verdict.
sed -e 's/^SPRRAM          equ     \$EB8000/SPRRAM          equ     $EB8001/' \
    -e 's/^SPRRAM_END      equ     \$EC0000/SPRRAM_END      equ     $EC0001/' \
    ../x68post.s > /tmp/sprfault.s
( cd .. && python3 build.py --src /tmp/sprfault.s --out test/build_sprfault ) >/dev/null
mkrom roms_sprfault build_sprfault/ipl_post.dat
printf '  faulting sprite test  '
run roms_sprfault 2m screen.lua 60 | grep -E 'Sprite RAM' | tr -s ' ' | tr '\n' ' '; echo
rm -rf roms_sprfault build_sprfault /tmp/sprfault.s

echo
echo "=== optional hardware is detected, not guessed ==="
printf '  MIDI absent           '
run roms 4m screen.lua 40 | grep -E 'MIDI' | tr -s ' ' | tr '\n' ' '; echo
printf '  MIDI fitted           '
mame x68kxvi -rompath roms -bios ipl12 -ram 4m -exp1 x68k_midi -video none -sound none \
  -window -nomaximize -nothrottle -seconds_to_run 40 -autoboot_script screen.lua \
  -autoboot_delay 0 2>&1 | grep -E 'MIDI' | tr -s ' ' | tr '\n' ' '; echo


echo
echo "=== serial byte stream ==="
run roms 2m serialcap.lua 14 | tail -3

rm -rf roms_cg roms_ipl /tmp/ipl_bad.dat
