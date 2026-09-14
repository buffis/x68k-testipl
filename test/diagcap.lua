-- Capture the whole RS-232C byte stream for a DIAG build.
--
-- serialcap.lua dumps as soon as the summary line appears, which on a
-- diagnostic build is the wrong moment: the diag section clears the screen and
-- restarts the row counter, so the trigger fires halfway through.  This just
-- taps channel A and dumps everything when the run ends.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local out = {}
_G.tap = mem:install_write_tap(0xe98006, 0xe98007, "scc_tx", function (offset, data, mask)
  out[#out+1] = string.char(data & 0xff)
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
