-- Inject a stuck DRAM bit at $80000 -- inside the pattern-tested region rather
-- than on a megabyte boundary, so the failure is caught by mem_verify and
-- reports as "exp/got" rather than as a stuck-bit mask.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
_G.tap = mem:install_read_tap(0x80000, 0x800ff, "stuckbit", function (o, d, m)
  return d | 0x0100
end)
dofile("screen.lua")
