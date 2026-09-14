-- Does MAME's RP5C15 actually tick during a run?
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n = 0
_G.keep = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if n % 55 ~= 0 then return end
  local s0 = mem:read_u8(0xe8a001) & 0x0f
  local s1 = mem:read_u8(0xe8a003) & 0x0f
  local m0 = mem:read_u8(0xe8a005) & 0x0f
  print(string.format("frame %5d  time %6.2fs  MMSS=%x%x%x", n,
        manager.machine.time.seconds + 0.0, m0, s1, s0))
end)
