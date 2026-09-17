#!/bin/sh
# Build and test injected TEST-IPL images.  Checks, for each IPL, that the
# payload lands in unprogrammed space, that the tests run, and that the machine
# then reaches the IPL on its own with nothing pressed.
set -e
cd "$(dirname "$0")"

# -video none still creates a window: renderer_none attaches to an osd_window
# and window_init runs unconditionally.  SDL's dummy driver stops that.
export SDL_VIDEODRIVER=dummy
STOCK=../../x68kxvi

# Image paths are relative to the repo root, where build.py is run.
# stock-ace is the tightest fit of any image we inject into -- a few hundred
# bytes spare -- so it is the one that catches the payload outgrowing a stock
# Sharp IPL.  x68030 covers the 32-bit bus.
for spec in "exbios:exbios/exbios_v1.34.24_220429.rom:x68000:ipl10:iplrom.dat" \
            "stock-ace:../x68kxvi/iplrom.dat:x68000:ipl10:iplrom.dat" \
            "x68030:../x68kxvi/iplrom30.dat:x68030:ipl13:iplrom30.dat"; do
  name=$(echo $spec | cut -d: -f1);  img=$(echo $spec | cut -d: -f2)
  mach=$(echo $spec | cut -d: -f3); bios=$(echo $spec | cut -d: -f4)
  iplname=$(echo $spec | cut -d: -f5)
  bdir=build_inj_$name

  echo "########## $name ##########"
  ( cd .. && python3 build.py --ipl "$img" --out "test/$bdir" ) | grep -E 'payload|chains to|WARNING|spare'

  d=roms_inj_$name
  rm -rf $d; mkdir -p $d/tmp
  cp $STOCK/cgrom.dat $STOCK/iplrom*.dat $STOCK/*.bin $STOCK/*.ic11 $STOCK/*.ic12 $d/tmp/ 2>/dev/null
  # MAME's x68030 set wants an scsiinrom.dat we do not have; a stand-in only has
  # to satisfy the loader, since our ROM never calls into it.
  [ $mach = x68030 ] && cp $STOCK/scsiinco.bin $d/tmp/scsiinrom.dat
  # Boot the stock ROM once first so SRAM is initialised.  MAME starts with
  # blank NVRAM, which the signature test correctly reads as a flat backup
  # battery, and TEST-IPL never writes SRAM.  Without this the first spec in
  # the loop reports a spurious SRAM signature FAIL and later ones do not.
  rm -rf ${d}_stock; mkdir -p ${d}_stock
  cp $d/tmp/* ${d}_stock/ 2>/dev/null
  ( cd ${d}_stock && zip -q -j ./$mach.zip ./* \
    && rm -f ./*.dat ./*.bin ./*.ic11 ./*.ic12 )
  mame $mach -rompath ./${d}_stock -bios $bios -ram 4m -video none -sound none \
    -window -nomaximize -nothrottle -seconds_to_run 14 >/dev/null 2>&1 || true

  cp $bdir/testipl.dat $d/tmp/$iplname
  ( cd $d/tmp && zip -q -j ../$mach.zip ./* )
  rm -rf $d/tmp

  run () {  # run <script> <seconds> [KEYCODE]
    KEYCODE=$3 mame $mach -rompath ./$d -bios $bios -ram 4m -video none -sound none \
      -window -nomaximize -nothrottle -seconds_to_run "$2" -autoboot_script "$1" \
      -autoboot_delay 0 2>&1 \
      | grep -viE 'wrong|expected:|found:|warning|iplrom|average|checksum problem'
  }

  # The report is transient, since the IPL clears the screen on its way to
  # booting, so capture it from the serial tap: that dumps at machine stop
  # rather than waiting for the cursor to settle.
  printf '  TEST-IPL runs         '
  got=$(run serialstop.lua 60 | grep -E 'PASSED|TEST\(S\) FAILED' | tr '\n' ' ')
  if [ -n "$got" ]; then
    echo "$got"
  else
    # MAME's x68030 SCC never reports tx-ready, so TEST-IPL correctly disables
    # serial there and this tap sees nothing.  The stock assembly build behaves
    # identically, so it is a property of the emulation, not of the ROM.
    # bootthru's row count below is the evidence that the report ran.
    echo "(no serial under MAME on this model -- see row count below)"
  fi
  printf '  boots through         '
  run bootthru.lua 90 | grep -E 'BOOTED THROUGH' | tr '\n' ' '; echo

  # Reaching the IPL is not the same as the IPL booting properly.  Compare the
  # booted screen against the same IPL with nothing injected, which catches
  # TEST-IPL leaving the machine in a state the IPL does not recover from.
  # Both runs are sampled the same interval after the IPL starts, since the
  # injected one spends ~14 s in TEST-IPL first.
  b=roms_base_$name
  rm -rf $b; mkdir -p $b/tmp
  cp $STOCK/cgrom.dat $STOCK/iplrom*.dat $STOCK/*.bin $STOCK/*.ic11 $STOCK/*.ic12 $b/tmp/ 2>/dev/null
  [ $mach = x68030 ] && cp $STOCK/scsiinco.bin $b/tmp/scsiinrom.dat
  cp "../$img" $b/tmp/$iplname 2>/dev/null || cp "$img" $b/tmp/$iplname
  ( cd $b/tmp && zip -q -j ../$mach.zip ./* )
  rm -rf $b/tmp

  base=$(mame $mach -rompath ./$b -bios $bios -ram 4m -video none -sound none \
    -window -nomaximize -nothrottle -seconds_to_run 120 -autoboot_script bootpix.lua \
    -autoboot_delay 0 2>&1 | grep -oE 'screen [0-9A-F]+ lit [0-9]+')
  with=$(run bootpix.lua 120 | grep -oE 'screen [0-9A-F]+ lit [0-9]+')
  printf '  boots the same        '
  lit=$(echo "$base" | grep -oE 'lit [0-9]+' | grep -oE '[0-9]+')
  if [ -z "$base" ] || [ -z "$with" ]; then
    echo "*** NO SAMPLE: without [$base] with [$with]"
  elif [ "${lit:-0}" -eq 0 ]; then
    # Both screens are blank at the sample point, so comparing them proves
    # nothing.  Say so rather than reporting a pass: a vacuous check is worse
    # than no check, because it looks like coverage.
    echo "*** VACUOUS: both screens blank at the sample point ($base)"
  elif [ "$base" = "$with" ]; then
    echo "identical: $with"
  else
    echo "*** DIFFERS: without TEST-IPL [$base]  with TEST-IPL [$with]"
  fi
  echo
done
