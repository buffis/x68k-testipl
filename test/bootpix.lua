-- Fingerprint the booted screen, for comparing an injected build against the
-- same IPL on its own.
--
-- Checksums the pixel values, deliberately not a count of non-black pixels:
-- MAME returns ARGB, so black is $FF000000 and "p ~= 0" holds for almost every
-- pixel on screen -- that just counts the active display area, which is the
-- same number whatever is displayed.
--
-- A fixed frame number will not do either, since the injected build spends
-- ~14 s in TEST-IPL first and the two runs would be sampled at different points
-- of the boot.  Find when the IPL starts -- TEST-IPL lives below $FF0000 and
-- the IPL at or above it -- and sample a fixed interval after that.
local SETTLE = 2090            -- frames after the IPL starts, ~38 s
local cpu = manager.machine.devices[":maincpu"]
local scr = manager.machine.screens[":screen"]
local frame, t0, done = 0, nil, false

_G.pwatch = emu.add_machine_frame_notifier(function ()
  frame = frame + 1
  if done then return end
  if not t0 then
    if cpu.state["PC"].value >= 0xff0000 then t0 = frame end
    return
  end
  if frame < t0 + SETTLE then return end
  done = true
  local h, lit = 2166136261, 0
  for y = 0, scr.height - 1 do
    for x = 0, scr.width - 1 do
      local p = scr:pixel(x, y)
      if (p & 0x00ffffff) ~= 0 then lit = lit + 1 end
      h = ((h ~ (p & 0xffffffff)) * 16777619) & 0xffffffff
    end
  end
  print(string.format("screen %08X lit %d (IPL started at frame %d)", h, lit, t0))
end)
