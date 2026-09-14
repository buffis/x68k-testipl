-- Does the stock IPL install its own bus/address error vectors, and when?
-- Taps writes to $000-$03F during a stock boot and reports each one.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local seen = 0
_G.tap = mem:install_write_tap(0x000000, 0x00003f, "vectors", function (offset, data, mask)
  seen = seen + 1
  if seen <= 40 then
    print(string.format("t=%8.4fs  write vector $%03X <- %08X   from PC=$%06X",
      manager.machine.time.seconds + 0.0, offset & ~3, data, cpu.state["PC"].value))
  end
  return data
end)
emu.add_machine_stop_notifier(function () print("total vector writes: " .. seen) end)
