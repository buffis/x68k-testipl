#!/bin/sh
# Run the standalone TEST-IPL on every model MAME emulates.
#
# There is one ROM image for all of them: it owns the machine from reset and
# boots nothing, so there is no stock IPL to fit around and nothing that varies
# by model.  MAME just wants the image under the filename each machine's
# BIOS expects.
cd "$(dirname "$0")"

# MAME's -video none still creates a window: renderer_none attaches to an
# osd_window and window_init runs unconditionally, so a real window appears and
# takes focus.  SDL's dummy video driver stops it reaching the display at all.
export SDL_VIDEODRIVER=dummy
STOCK=../../x68kxvi
ROM=${ROM:-../build/ipl_testipl.dat}

for spec in "xvi:x68kxvi:ipl11:iplromxv.dat" \
            "ace:x68000:ipl10:iplrom.dat" \
            "x68030:x68030:ipl13:iplrom30.dat" \
            "compact:x68kxvi:ipl12:iplromco.dat"; do
  model=$(echo $spec | cut -d: -f1); mach=$(echo $spec | cut -d: -f2)
  bios=$(echo $spec | cut -d: -f3);  iplname=$(echo $spec | cut -d: -f4)
  d=roms_$model
  rm -rf $d; mkdir -p $d/tmp
  cp $STOCK/cgrom.dat $STOCK/iplrom*.dat $STOCK/*.bin $STOCK/*.ic11 $STOCK/*.ic12 $d/tmp/ 2>/dev/null
  # MAME's x68030 set wants an scsiinrom.dat we do not have; a stand-in only
  # has to satisfy the loader, since our ROM never calls into it.
  [ $mach = x68030 ] && cp $STOCK/scsiinco.bin $d/tmp/scsiinrom.dat
  # A stock rompath as well as ours.  Booting the stock ROM once initialises
  # SRAM: MAME starts with blank NVRAM, which is a flat backup battery as far as
  # the signature test is concerned, and our ROM never writes SRAM because it
  # boots nothing.  Each machine keeps its own NVRAM, so each needs its own
  # warm-up -- without this, models nothing else happens to have booted report a
  # spurious SRAM signature FAIL.
  rm -rf ${d}_stock; mkdir -p ${d}_stock
  cp $d/tmp/* ${d}_stock/ 2>/dev/null
  (cd ${d}_stock && zip -q -j ./$mach.zip ./* && rm -f ./*.dat ./*.bin ./*.ic11 ./*.ic12)

  cp $ROM $d/tmp/$iplname
  (cd $d/tmp && zip -q -j ../$mach.zip ./*)
  rm -rf $d/tmp

  mame $mach -rompath ./${d}_stock -bios $bios -ram 4m -video none -sound none \
    -window -nomaximize -nothrottle -seconds_to_run 14 >/dev/null 2>&1 || true

  echo "########## $model  ->  mame $mach -bios $bios ##########"
  mame $mach -rompath ./$d -bios $bios -ram 4m -video none -sound none -window -nomaximize -nothrottle \
    -seconds_to_run 40 -autoboot_script screen.lua -autoboot_delay 0 2>&1 \
    | grep -viE 'wrong|expected:|found:|warning|iplrom|average|checksum problem'
  echo
done
