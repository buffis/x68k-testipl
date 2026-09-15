#!/bin/sh
# Build and test injected POST images: the POST runs, then hands the machine
# over to whatever IPL it was injected into.
#
#   ./tryinject.sh
#
# Checks, for each IPL: that the payload lands in unprogrammed space, that the
# POST runs, and that the machine then reaches the IPL on its own with nothing
# pressed.
set -e
cd "$(dirname "$0")"

# MAME's -video none still creates a window: renderer_none attaches to an
# osd_window and window_init runs unconditionally, so a real window appears and
# takes focus.  SDL's dummy video driver stops it reaching the display at all.
export SDL_VIDEODRIVER=dummy
STOCK=../../x68kxvi

# Image paths are relative to post/, because build.py is run from there.
for spec in "exbios:exbios/exbios_v1.34.24_220429.rom:x68000:ipl10:iplrom.dat" \
            "stock-ace:../x68kxvi/iplrom.dat:x68000:ipl10:iplrom.dat"; do
  name=$(echo $spec | cut -d: -f1);  img=$(echo $spec | cut -d: -f2)
  mach=$(echo $spec | cut -d: -f3); bios=$(echo $spec | cut -d: -f4)
  iplname=$(echo $spec | cut -d: -f5)
  bdir=build_inj_$name

  echo "########## $name ##########"
  ( cd .. && python3 build.py --ipl "$img" --out "test/$bdir" ) | grep -E 'payload|chains to'

  d=roms_inj_$name
  rm -rf $d; mkdir -p $d/tmp
  cp $STOCK/cgrom.dat $STOCK/iplrom*.dat $STOCK/*.bin $STOCK/*.ic11 $STOCK/*.ic12 $d/tmp/ 2>/dev/null
  # Boot the stock ROM once first so SRAM is initialised.  MAME starts with
  # blank NVRAM, which the signature test correctly reads as a flat backup
  # battery, and the POST never writes SRAM itself.  Without this the first
  # spec in the loop reports a spurious SRAM signature FAIL while later ones
  # pass, purely because an earlier iteration happened to warm the machine.
  rm -rf ${d}_stock; mkdir -p ${d}_stock
  cp $d/tmp/* ${d}_stock/ 2>/dev/null
  ( cd ${d}_stock && zip -q -j ./$mach.zip ./* \
    && rm -f ./*.dat ./*.bin ./*.ic11 ./*.ic12 )
  mame $mach -rompath ./${d}_stock -bios $bios -ram 4m -video none -sound none \
    -window -nomaximize -nothrottle -seconds_to_run 14 >/dev/null 2>&1 || true

  cp $bdir/ipl_post.dat $d/tmp/$iplname
  ( cd $d/tmp && zip -q -j ../$mach.zip ./* )
  rm -rf $d/tmp

  run () {  # run <script> <seconds> [KEYCODE]
    KEYCODE=$3 mame $mach -rompath ./$d -bios $bios -ram 4m -video none -sound none \
      -window -nomaximize -nothrottle -seconds_to_run "$2" -autoboot_script "$1" \
      -autoboot_delay 0 2>&1 \
      | grep -viE 'wrong|expected:|found:|warning|iplrom|average|checksum problem'
  }

  # The report is transient -- the IPL clears the screen on its way to booting --
  # so capture it from the serial tap, which dumps at machine stop rather than
  # waiting for the cursor to settle.
  printf '  POST runs             '
  run serialstop.lua 60 | grep -E 'PASSED|TEST\(S\) FAILED' | tr '\n' ' '; echo
  printf '  boots through         '
  run bootthru.lua 90 | grep -E 'BOOTED THROUGH' | tr '\n' ' '; echo

  # Reaching the IPL is not the same as the IPL booting properly.  Compare the
  # booted screen against the same IPL with no POST in it: if the POST leaves
  # the machine in a state the IPL does not fully recover from, this is what
  # catches it.  Both runs are sampled the same interval after the IPL starts,
  # since the injected one spends ~14 s in the POST first.
  b=roms_base_$name
  rm -rf $b; mkdir -p $b/tmp
  cp $STOCK/cgrom.dat $STOCK/iplrom*.dat $STOCK/*.bin $STOCK/*.ic11 $STOCK/*.ic12 $b/tmp/ 2>/dev/null
  cp "../$img" $b/tmp/$iplname 2>/dev/null || cp "$img" $b/tmp/$iplname
  ( cd $b/tmp && zip -q -j ../$mach.zip ./* )
  rm -rf $b/tmp

  base=$(mame $mach -rompath ./$b -bios $bios -ram 4m -video none -sound none \
    -window -nomaximize -nothrottle -seconds_to_run 120 -autoboot_script bootpix.lua \
    -autoboot_delay 0 2>&1 | grep -oE 'screen [0-9A-F]+ lit [0-9]+')
  with=$(run bootpix.lua 120 | grep -oE 'screen [0-9A-F]+ lit [0-9]+')
  printf '  boots the same        '
  if [ -n "$base" ] && [ "$base" = "$with" ]; then
    echo "identical: $with"
  else
    echo "*** DIFFERS: without POST [$base]  with POST [$with]"
  fi
  echo
done
