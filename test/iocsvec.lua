-- IOCS call vectors live at $000400, one longword per call number.  Read the
-- sprite group out of a booted machine rather than hunting for the ROM table.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n = 0
_G.v = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if n ~= 1500 then return end
  local names = {[0xc0]="_SP_INIT", [0xc1]="_SP_ON", [0xc2]="_SP_OFF",
                 [0xc3]="_SP_CGCLR", [0xc4]="_SP_DEFCG", [0xc6]="_SP_REGST",
                 [0xc8]="_BGSCRLST", [0xc9]="_BGCTRLST"}
  for call = 0xc0, 0xcb do
    local a = mem:read_u32(0x400 + call * 4)
    print(string.format("IOCS $%02X %-10s -> $%06X", call, names[call] or "", a))
  end
end)
