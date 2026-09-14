local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local n, done = 0, false
_G.keep = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if done or n % 11 ~= 0 then return end
  if mem:read_u16(0xe7ff02) < 20 then return end
  done = true
  local hit = 0
  for y = 41, 552, 2 do for x = 225, 992, 2 do
    -- MAME returns ARGB, so black is $FF000000, not 0: mask the alpha off
    -- or this counts every pixel in the active display area.
    if (scr:pixel(x,y) & 0x00ffffff) ~= 0 then hit = hit + 1 end
  end end
  print("non-black pixels (sampled): " .. hit)
  manager.machine.video:snapshot()
end)
