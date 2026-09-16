-- Report how much of the 3840-byte stack TEST-IPL actually used.
--
-- crt0.s paints $E7F000-$E7FEF7 with $DEADBEEF after the second stack probe.
-- The stack grows down from $E7FF00, so the high-water mark is the lowest
-- address whose paint survived.  An overflow past $E7F000 would be silent --
-- it runs into text VRAM rows nothing displays -- so this is the only way to
-- see it coming.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local BASE, TOP = 0xe7f000, 0xe7ff00

local function report()
  local first = TOP
  for a = BASE, TOP - 4, 4 do
    if mem:read_u32(a) ~= 0xdeadbeef then first = a break end
  end
  local used = TOP - first
  print(string.format("stack high-water %d of %d bytes (%.0f%%)",
                      used, TOP - BASE, used * 100.0 / (TOP - BASE)))
end

if emu.add_machine_stop_notifier then
  _G.st = emu.add_machine_stop_notifier(report)
end
