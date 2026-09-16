-- Inject a stuck DRAM bit at $100000 and show what the TEST-IPL makes of it.
-- Run against a 2M machine:  RAMSIZE=2M ./run-mame.sh fault
local mem = manager.machine.devices[":maincpu"].spaces["program"]
_G.tap = mem:install_read_tap(0x100000, 0x1000ff, "stuckbit", function (o, d, m)
  return d | 0x0040                        -- bit 6 always reads back high
end)
dofile("screen.lua")
