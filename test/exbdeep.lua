-- Longer trace: does exbios ever touch AREASET, sprite RAM, or the DMAC, and
-- what is the biggest thing it does to main DRAM early on?
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local seen = {}
local function once(key, msg)
  if seen[key] then return end
  seen[key] = true
  print(msg)
end
_G.a = mem:install_write_tap(0xe86000, 0xe87fff, "areaset", function (o,d,m)
  once("areaset", string.format("AREASET   $%06X <- %04X  PC $%06X", o, d & 0xffff, cpu.state["PC"].value))
  return d end)
_G.b = mem:install_write_tap(0xeb8000, 0xebffff, "sprram", function (o,d,m)
  once("sprram", string.format("SPRITE RAM write $%06X <- %04X  PC $%06X", o, d & 0xffff, cpu.state["PC"].value))
  return d end)
_G.c = mem:install_read_tap(0xeb8000, 0xebffff, "sprramr", function (o,d,m)
  once("sprramr", string.format("SPRITE RAM read  $%06X  PC $%06X", o, cpu.state["PC"].value))
  return d end)
_G.d = mem:install_write_tap(0xeb0800, 0xeb0811, "sprreg", function (o,d,m)
  once("sprreg"..o, string.format("SPRITE REG $%06X <- %04X  PC $%06X", o, d & 0xffff, cpu.state["PC"].value))
  return d end)
_G.e = mem:install_write_tap(0xe84000, 0xe85fff, "dmac", function (o,d,m)
  once("dmac", string.format("DMAC first write $%06X <- %04X  PC $%06X", o, d & 0xffff, cpu.state["PC"].value))
  return d end)
_G.f = mem:install_write_tap(0xe8e000, 0xe8ffff, "sys", function (o,d,m)
  once("sys"..o, string.format("SYSPORT   $%06X <- %04X  PC $%06X", o, d & 0xffff, cpu.state["PC"].value))
  return d end)
