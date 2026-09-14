-- Log every write the stock IPL makes to the sprite/BG controller registers.
-- Several of them read back $FF, so reading the state after boot is not enough
-- to know what was programmed.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local seen = 0
_G.stap = mem:install_write_tap(0xeb0800, 0xeb0811, "sprregs", function (o, d, m)
  seen = seen + 1
  if seen <= 40 then
    print(string.format("t=%7.3fs  $%06X <- %04X  mask %08X  from PC $%06X",
      manager.machine.time.seconds + 0.0, o, d & 0xffff, m, cpu.state["PC"].value))
  end
  return d
end)
emu.add_machine_stop_notifier(function () print("total sprite reg writes: " .. seen) end)
