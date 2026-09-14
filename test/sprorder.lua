-- What does a stock IPL do, in order, before it first touches sprite RAM?
-- Our POST now replays the sprite register writes and still fails on hardware,
-- so something earlier in the sequence must be the enabling step.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local log, firstram, n = {}, nil, 0

local function note(kind, o, d)
  n = n + 1
  if n > 60 then return end
  print(string.format("%-6s $%06X <- %04X   PC $%06X", kind, o, d & 0xffff,
                      cpu.state["PC"].value))
end
_G.t1 = mem:install_write_tap(0xe82000, 0xe82fff, "vc",  function (o,d,m) note("VC", o,d) return d end)
_G.t2 = mem:install_write_tap(0xeb0000, 0xeb0fff, "spr", function (o,d,m) note("SPRREG", o,d) return d end)
_G.t3 = mem:install_write_tap(0xeb8000, 0xebffff, "ram", function (o,d,m)
  if not firstram then
    firstram = true
    print(string.format(">>>> first sprite RAM write $%06X <- %04X at PC $%06X",
                        o, d & 0xffff, cpu.state["PC"].value))
  end
  return d
end)
_G.t4 = mem:install_read_tap(0xeb8000, 0xebffff, "ramr", function (o,d,m)
  if not firstram then
    firstram = true
    print(string.format(">>>> first sprite RAM read  $%06X at PC $%06X",
                        o, cpu.state["PC"].value))
  end
  return d
end)

