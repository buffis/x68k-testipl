-- Freeze the MFP GPIP so no bit ever changes, simulating a CRTC that is not
-- scanning -- and specifically the undriven-bus case ($FF constantly), which
-- is what fooled the old CRTC readback test.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
_G.tap = mem:install_read_tap(0xe88000, 0xe88001, "gpipfreeze", function (o, d, m)
  return 0xffff
end)
dofile("screen.lua")
