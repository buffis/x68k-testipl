-- Does exbios ever write high DRAM, and how big a burst does it ever do?
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local seen, runs, last, cur, best, bestpc = {}, 0, -8, 0, 0, 0
local function once(k, m) if not seen[k] then seen[k] = true print(m) end end
_G.h1 = mem:install_write_tap(0x100000, 0x1000ff, "hi1", function (o,d,m)
  once("1m", string.format("first write at $100000 region: PC $%06X", cpu.state["PC"].value)) return d end)
_G.h2 = mem:install_write_tap(0x300000, 0x3000ff, "hi3", function (o,d,m)
  once("3m", string.format("first write at $300000 region: PC $%06X", cpu.state["PC"].value)) return d end)
-- longest run of consecutive-address writes anywhere in low DRAM
_G.h3 = mem:install_write_tap(0x000400, 0x0fffff, "run", function (o,d,m)
  if o == last + 4 or o == last + 2 then
    cur = cur + 1
    if cur > best then
      best, bestpc = cur, cpu.state["PC"].value
      if best % 64 == 0 or best == 16 then
        print(string.format("consecutive DRAM write run reached %d (PC $%06X)", best, bestpc))
      end
    end
  else cur = 1 end
  last = o
  return d
end)

