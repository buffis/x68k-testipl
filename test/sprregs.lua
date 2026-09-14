-- What does a stock IPL leave in the sprite/BG controller after it boots?
-- Our POST never programs any of it, which is the obvious difference between
-- us and MTEST: MTEST runs under Human68k, on a controller the IPL set up.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n = 0
_G.sw = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if n ~= 1500 then return end
  local out = {}
  for a = 0xeb0800, 0xeb0811, 2 do
    out[#out+1] = string.format("$%06X=%04X", a, mem:read_u16(a))
  end
  print("sprite regs: " .. table.concat(out, " "))
  print(string.format("VC R0=%04X R1=%04X R2=%04X",
    mem:read_u16(0xe82400), mem:read_u16(0xe82500), mem:read_u16(0xe82600)))
end)
