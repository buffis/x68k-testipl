-- Fingerprint the booted screen, for comparing an injected build against the
-- same IPL on its own.  Reaching the IPL is not the same as the IPL booting
-- properly: if TEST-IPL leaves the machine in a state the IPL cannot recover
-- from, this is what catches it.
--
-- Checksums the pixel values, deliberately not a count of non-black pixels:
-- MAME returns ARGB, so black is $FF000000 and "p ~= 0" holds for almost every
-- pixel on screen -- that just counts the active display area, which is the
-- same number whatever is displayed.
--
-- Finding the moment to sample is the awkward part.
--
-- A fixed frame number will not do, since the injected build spends ~14 s in
-- TEST-IPL first and the two runs would reach the same boot stage at very
-- different frames.  So wait for the IPL to take over -- TEST-IPL always links
-- below $FF0000 and the IPL sits at or above it -- and measure from there.
--
-- A fixed offset after that does not work either.  The x68030 IPL under MAME
-- puts up a screen for about 130 frames and then blanks it for good, so the
-- offset that suits the x68000 (~2000 frames) samples pure black there and the
-- comparison passes vacuously against another black screen.  Instead, sample
-- once the picture has stopped changing AND is not blank.  That lands inside
-- the x68030's brief window and on the x68000's settled boot screen, without
-- either needing to know which model it is.
--
-- If nothing lit ever settles, report anyway with lit 0: the caller treats that
-- as a vacuous comparison rather than a pass.
local STABLE = 24       -- frames the picture must hold still
local LIMIT  = 4000     -- give up this many frames after the IPL starts

local cpu = manager.machine.devices[":maincpu"]
local scr = manager.machine.screens[":screen"]
local frame, t0, done = 0, nil, false
local lastsig, held = nil, 0

-- Cheap per-frame signature: every 8th pixel, enough to see the picture change
-- without reading 400k pixels a frame.
local function sample()
  local sig, lit = 2166136261, 0
  for y = 0, scr.height - 1, 8 do
    for x = 0, scr.width - 1, 8 do
      local p = scr:pixel(x, y) & 0x00ffffff
      if p ~= 0 then lit = lit + 1 end
      sig = ((sig ~ p) * 16777619) & 0xffffffff
    end
  end
  return sig, lit
end

local function report()
  local h, lit = 2166136261, 0
  for y = 0, scr.height - 1 do
    for x = 0, scr.width - 1 do
      local p = scr:pixel(x, y)
      if (p & 0x00ffffff) ~= 0 then lit = lit + 1 end
      h = ((h ~ (p & 0xffffffff)) * 16777619) & 0xffffffff
    end
  end
  print(string.format("screen %08X lit %d (IPL started at frame %d, sampled at IPL+%d)",
                      h, lit, t0, frame - t0))
end

_G.pwatch = emu.add_machine_frame_notifier(function ()
  frame = frame + 1
  if done then return end

  if not t0 then
    if cpu.state["PC"].value >= 0xff0000 then t0 = frame end
    return
  end

  local sig, lit = sample()
  if sig ~= lastsig then
    lastsig, held = sig, 0
  else
    held = held + 1
  end

  if (held >= STABLE and lit > 0) or (frame - t0) > LIMIT then
    done = true
    report()
  end
end)
