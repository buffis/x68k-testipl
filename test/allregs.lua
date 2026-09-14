-- Every distinct hardware address exbios writes during a full boot, with the
-- first value and PC for each.  A systematic sweep, so "is there anything we
-- have not accounted for" gets an answer instead of a guess.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local seen, order = {}, {}
_G.t = mem:install_write_tap(0xe80000, 0xefffff, "all", function (o, d, m)
  if not seen[o] then
    seen[o] = string.format("$%06X <- %04X  PC $%06X", o, d & 0xffff, cpu.state["PC"].value)
    order[#order+1] = o
  end
  return d
end)
local n = 0
_G.k = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if n ~= 1200 then return end
  table.sort(order)
  print("distinct addresses written: " .. #order)
  for _, o in ipairs(order) do print("  " .. seen[o]) end
end)
