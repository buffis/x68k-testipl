-- Where does the 68000 actually fetch its reset vector on an X68000?
-- Tap reads of $000000-$000007 and $FF0000-$FF0007 and report the first few.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n = 0
local function tap(lo, hi, label)
  return mem:install_read_tap(lo, hi, label, function (offset, data, mask)
    n = n + 1
    if n <= 12 then
      print(string.format("%-10s read $%06X  mask=%08X  data=%08X  t=%.6fs",
            label, offset, mask, data, manager.machine.time.seconds + 0.0))
    end
    return data
  end)
end
_G.t1 = tap(0x000000, 0x000007, "low")
_G.t2 = tap(0xff0000, 0xff0007, "iplrom")
