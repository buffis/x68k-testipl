-- What does a stock IPL write to the memory controller and system port, and
-- when, relative to it first hammering main DRAM?  Our POST touches neither.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local n, dram = 0, false
local function note(kind, o, d, m)
  n = n + 1
  if n > 30 then return end
  print(string.format("%-8s $%06X <- %04X mask %08X  PC $%06X  t=%.4f",
        kind, o, d & 0xffff, m, cpu.state["PC"].value, manager.machine.time.seconds + 0.0))
end
_G.a1 = mem:install_write_tap(0xe86000, 0xe87fff, "areaset", function (o,d,m) note("AREASET",o,d,m) return d end)
_G.a2 = mem:install_write_tap(0xe8e000, 0xe8ffff, "sysport", function (o,d,m) note("SYSPORT",o,d,m) return d end)
_G.a3 = mem:install_write_tap(0x001000, 0x00100f, "dram", function (o,d,m)
  if not dram then
    dram = true
    print(string.format(">>>> first write to main DRAM $%06X at PC $%06X t=%.4f",
          o, cpu.state["PC"].value, manager.machine.time.seconds + 0.0))
  end
  return d
end)
