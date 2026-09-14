local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local n, done, chained = 0, nil, nil
_G.keep = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if not done and mem:read_u16(0xe7ff02) >= 20 then
    done = n
    io.stderr:write(string.format("tests finished at %.1fs\n", n/55.0))
  end
  if done and not chained then
    local pc = cpu.state["PC"].value
    if pc < 0xffe000 then
      chained = n
      io.stderr:write(string.format("chained to stock IPL at %.1fs (pause %.1fs)\n",
        n/55.0, (n-done)/55.0))
    end
  end
end)
