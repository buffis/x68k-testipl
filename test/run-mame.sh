#!/bin/sh
# Run the standalone POST ROM under MAME.
#
#   ./run-mame.sh                 watch the standalone build in a window
#   ./run-mame.sh exbios          watch the exbios build boot, in a window
#   ./run-mame.sh screen          print the result screen as text
#   ./run-mame.sh serial          print the bytes sent to the RS-232C port
#   ./run-mame.sh fault           inject a stuck DRAM bit and show the result
#   ./run-mame.sh gpip            freeze the MFP GPIP and show the result
#
# Set RAM to test a different machine size, e.g.  RAM=2m ./run-mame.sh screen
# (RAM is a slot device in current MAME: -ram 4m, not -ramsize 4M.)
#
# One image serves every model; this drives the Compact profile because that is
# what MAME's x68kxvi/ipl12 wants the file called.  Use tryall.sh for the rest.
set -e
cd "$(dirname "$0")"

# Captured before the defaults below assign anything, so a per-mode default can
# tell "caller did not set it" from "already defaulted to the standalone build".
BUILD_SET=${BUILD:-}

ROMDIR=${ROMDIR:-./roms}
RAM=${RAM:-4m}
STOCK=${STOCK:-../../x68kxvi}
BUILD=${BUILD:-../build}

mkdir -p "$ROMDIR"
rm -rf "$ROMDIR/tmp" "$ROMDIR/x68kxvi.zip"
mkdir -p "$ROMDIR/tmp"
cp "$STOCK"/cgrom.dat "$STOCK"/iplrom*.dat "$STOCK"/*.bin "$STOCK"/*.ic11 \
   "$STOCK"/*.ic12 "$ROMDIR/tmp/" 2>/dev/null || true
cp "$BUILD/ipl_post.dat" "$ROMDIR/tmp/iplromco.dat"
( cd "$ROMDIR/tmp" && zip -q -j ../x68kxvi.zip ./* )
rm -rf "$ROMDIR/tmp"

if [ "${1:-window}" = "exbios" ]; then
  # The exbios build is a complete IPL in its own right, for the ace profile --
  # MAME wants it called iplrom.dat and run on the x68000 machine, not the
  # Compact's x68kxvi/ipl12 that every other mode here uses.
  BUILD=${BUILD_SET:-../build-exbios}
  ROMDIR=./roms_exbios_win
  rm -rf "$ROMDIR"; mkdir -p "$ROMDIR/tmp"
  cp "$STOCK"/cgrom.dat "$STOCK"/iplrom*.dat "$STOCK"/*.bin "$STOCK"/*.ic11 \
     "$STOCK"/*.ic12 "$ROMDIR/tmp/" 2>/dev/null || true
  cp "$BUILD/ipl_post.dat" "$ROMDIR/tmp/iplrom.dat"
  ( cd "$ROMDIR/tmp" && zip -q -j ../x68000.zip ./* )
  rm -rf "$ROMDIR/tmp"
  exec mame x68000 -rompath "$ROMDIR" -bios ipl10 -ram "$RAM" \
       -window -nomaximize -skip_gameinfo
fi

COMMON="x68kxvi -rompath $ROMDIR -bios ipl12 -ram $RAM"
# Everything except the window mode runs on SDL's dummy video driver, so MAME
# never opens a window or steals focus.  -video none alone does not prevent it.
[ "${1:-window}" = "window" ] || export SDL_VIDEODRIVER=dummy
HEADLESS="-video none -sound none -window -nomaximize -nothrottle"

case "${1:-window}" in
  window)  exec mame $COMMON -window -nomaximize ;;
  screen)  exec mame $COMMON $HEADLESS -seconds_to_run 40 \
             -autoboot_script screen.lua -autoboot_delay 0 ;;
  serial)  exec mame $COMMON $HEADLESS -seconds_to_run 14 \
             -autoboot_script serialcap.lua -autoboot_delay 0 ;;
  fault)   exec mame $COMMON $HEADLESS -seconds_to_run 20 \
             -autoboot_script faulttest.lua -autoboot_delay 0 ;;
  gpip)    exec mame $COMMON $HEADLESS -seconds_to_run 20 \
             -autoboot_script nogpip.lua -autoboot_delay 0 ;;
  *)       echo "usage: $0 [window|exbios|screen|serial|fault|gpip]" >&2; exit 2 ;;
esac
