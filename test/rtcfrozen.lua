-- Simulate a stopped oscillator: the chip answers perfectly, but the seconds
-- registers ($E8A001 units, $E8A003 tens) never change.  This is the classic
-- X68000 failure -- dead 32.768 kHz crystal or battery corrosion around it --
-- and the thing the old BCD plausibility check sailed straight past.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
_G.ftap = mem:install_read_tap(0xe8a000, 0xe8a003, "rtcfrozen", function (o, d, m)
  return 0x00040004          -- a legal, unchanging "44" seconds
end)
dofile("screen.lua")
