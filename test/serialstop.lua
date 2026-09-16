-- Capture the whole RS-232C byte stream, dumping at machine stop rather than on
-- cursor settle -- what an injected build needs, since the IPL takes the screen
-- over and the cursor never settles.
--
-- The tap covers $E98004-$E98007 rather than just the data port, because the
-- x68030 driver has a 32-bit bus and rejects a tap whose start address has low
-- bits set.  That means control-register writes come through it too, so the
-- callback works out which byte lane was actually written and keeps only
-- $E98007.  Lane 0 is the most significant byte on this big-endian bus.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local out = {}

_G.tap = mem:install_write_tap(0xe98004, 0xe98007, "scc_tx", function (offset, data, mask)
  local width = (mask > 0xffff) and 4 or 2
  for i = 0, width - 1 do
    local shift = (width - 1 - i) * 8
    if ((mask >> shift) & 0xff) ~= 0 and (offset + i) == 0xe98007 then
      out[#out + 1] = string.char((data >> shift) & 0xff)
    end
  end
  return data
end)

local function dump ()
  print("------ SCC channel A byte stream, " .. #out .. " bytes ------")
  io.write(table.concat(out))
end

if emu.add_machine_stop_notifier then
  _G.stopper = emu.add_machine_stop_notifier(dump)
else
  -- older API: fall back to dumping once the stream stops growing
  local last, still, n = 0, 0, 0
  _G.keep = emu.add_machine_frame_notifier(function ()
    n = n + 1
    if n % 60 ~= 0 then return end
    if #out == last then still = still + 1 else still, last = 0, #out end
    if still == 5 then dump(); still = -1000 end
  end)
end
