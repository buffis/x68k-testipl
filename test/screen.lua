-- Print the TEST-IPL result screen as text.
--
-- The text plane holds bitmaps, not character codes, so this builds a reverse
-- lookup from the CGROM 8x16 font and matches each 8x16 cell against it.  It
-- waits for the run to settle before dumping, since the timing depends on how
-- much RAM the machine has.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local FONT, P0, P1, STRIDE = 0xf3a800, 0xe00000, 0xe20000, 128
local W_COL, W_ROW = 0xe7ff00, 0xe7ff02

local glyphs, blank = {}, string.rep("00", 16)
for c = 32, 126 do
  local k = {}
  for i = 0, 15 do k[#k+1] = string.format("%02X", mem:read_u8(FONT + c*16 + i)) end
  glyphs[table.concat(k)] = string.char(c)
end

local function cell(plane, row, col)
  local k = {}
  for i = 0, 15 do
    k[#k+1] = string.format("%02X", mem:read_u8(plane + (row*16+i)*STRIDE + col))
  end
  return table.concat(k)
end

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
  local rc = mem:read_u32(W_COL)
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
  for row = 0, 31 do
    local line = {}
    for col = 0, 95 do
      local a, b = cell(P0, row, col), cell(P1, row, col)
      local g = (a ~= blank) and a or b
      line[#line+1] = (g == blank) and " " or (glyphs[g] or "#")
    end
    local t = table.concat(line):gsub("%s+$", "")
    if #t > 0 then print(t) end
  end
end)
