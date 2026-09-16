-- Capture what the TEST-IPL sends to the RS-232C port.
--
-- MAME's x68000 driver wires SCC channel B to the mouse and leaves channel A's
-- TxD unconnected, so the serial line itself cannot be observed.  Tap writes to
-- the channel A data port instead and rebuild the byte stream, which verifies
-- everything up to the pin.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local out = {}
_G.tap = mem:install_write_tap(0xe98006, 0xe98007, "scc_tx", function (offset, data, mask)
  out[#out+1] = string.char(data & 0xff)
  return data
end)
local n, shown = 0, false
_G.keep = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if shown or n % 11 ~= 0 then return end
  -- The run is done when the cursor stops advancing.  Both halves of it are
  -- needed: a fixed row breaks whenever a test is added or removed, and a test
  -- printing progress marks advances only the column.
  --
  -- Cursor position alone is not enough either -- test_dram rewrites its address
  -- field in place, so w_col returns to the same value after every update and a
  -- run in full flight looks finished.  Mix in a hash of the current row's
  -- pixels, which changes whenever the field does.  The whole scanline, not
  -- sampled columns: renaming a test shifts the progress field sideways, and
  -- fixed sample points then land on characters that never change.
  local rc = mem:read_u32(0xe7ff00)
  local r = rc & 0xffff
  local k = rc
  local rowbase = 0xe00000 + (r * 16) * 128
  for i = 0, 15 do
    local sl = rowbase + i * 128
    for col = 0, 124, 4 do
      k = (k * 31 + mem:read_u32(sl + col)) & 0xffffffff
    end
  end
  if k ~= _G.lastrow then _G.lastrow, _G.settled = k, 0; return end
  _G.settled = (_G.settled or 0) + 1
  if r < 8 or _G.settled < 20 then return end
  shown = true
  print("------ SCC channel A byte stream, " .. #out .. " bytes ------")
  io.write(table.concat(out))
end)
