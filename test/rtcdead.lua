-- Simulate an RP5C15 that does not answer its bus: alarm register 2 (bank 1,
-- $E8A005) reads back as a floating bus instead of what was written, so the
-- chip-and-bus check cannot see its own writes.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
_G.rtap = mem:install_read_tap(0xe8a004, 0xe8a005, "rtcdead", function (o, d, m)
  return 0x00ff
end)
dofile("screen.lua")
