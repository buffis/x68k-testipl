-- Does the stock IPL write the supervisor-area register, and when?
-- MAME does not implement it (areaset_w is a TODO), so this only tells us what
-- the IPL does -- but that is the recipe our POST is missing.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local n = 0
_G.ar = mem:install_write_tap(0xe86000, 0xe87fff, "areaset", function (o, d, m)
  n = n + 1
  if n <= 20 then
    print(string.format("AREASET $%06X <- %04X mask %08X  PC $%06X  t=%.4f",
          o, d & 0xffff, m, cpu.state["PC"].value, manager.machine.time.seconds + 0.0))
  end
  return d
end)
