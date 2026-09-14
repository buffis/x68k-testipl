-- Everything exbios writes from reset, anywhere, in order -- not just hardware
-- registers.  Consecutive ascending writes collapse into one "run" line so the
-- bulk fills do not drown the narrative.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local events, last, runstart, runcount, runpc = 0, -99, 0, 0, 0
local function flush()
  if runcount == 0 then return end
  if runcount == 1 then
    print(string.format("  $%06X            (PC $%06X)", runstart, runpc))
  else
    print(string.format("  $%06X..$%06X  run of %d   (PC $%06X)",
          runstart, last, runcount, runpc))
  end
  runcount = 0
end
_G.t = mem:install_write_tap(0x000000, 0xdfffff, "ram", function (o, d, m)
  if events > 120 then return d end
  if o == last + 2 or o == last + 4 then
    last = o; runcount = runcount + 1
  else
    flush(); events = events + 1
    runstart, last, runcount, runpc = o, o, 1, cpu.state["PC"].value
  end
  return d
end)
_G.r = mem:install_write_tap(0xe80000, 0xefffff, "reg", function (o, d, m)
  if events > 120 then return d end
  flush(); events = events + 1
  print(string.format("  $%06X <- %04X  REG   (PC $%06X)", o, d & 0xffff, cpu.state["PC"].value))
  last = -99
  return d
end)
