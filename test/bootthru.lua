-- An injected build must reach the IPL on its own, with no key pressed.
-- Watches for the PC to leave the TEST-IPL payload and settle in the IPL.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local frame, done, peak = 0, false, 0
_G.bwatch = emu.add_machine_frame_notifier(function ()
  frame = frame + 1
  local row = mem:read_u16(0xe7ff02)
  if row > peak then peak = row end
  if done then return end
  local pc = cpu.state["PC"].value
  if pc >= 0xff0000 and pc < 0xfff000 and peak >= 8 then
    done = true
    print(string.format("BOOTED THROUGH: PC $%06X at frame %d (report reached row %d)",
                        pc, frame, peak))
  end
end)
