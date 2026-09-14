-- What does exbios write to hardware, in order, from reset?  It boots the PRO
-- that our POST stalls on, so its sequence is known-good on that machine.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local n, dram = 0, false
local names = {
  [0xe80000]="CRTC", [0xe82400]="VIDEO", [0xe84000]="DMAC", [0xe86000]="AREASET",
  [0xe88000]="MFP", [0xe8a000]="RTC", [0xe8e000]="SYSPORT", [0xeb0000]="SPRITE",
}
local function label(o)
  for base, nm in pairs(names) do
    if o >= base and o < base + 0x2000 then return nm end
  end
  return "?"
end
local function tap(lo, hi)
  return mem:install_write_tap(lo, hi, "t", function (o, d, m)
    n = n + 1
    if n <= 45 then
      print(string.format("%-8s $%06X <- %04X mask %08X  PC $%06X",
            label(o), o, d & 0xffff, m, cpu.state["PC"].value))
    end
    return d
  end)
end
_G.t1 = tap(0xe80000, 0xe81fff)   -- CRTC
_G.t2 = tap(0xe82400, 0xe82fff)   -- video controller
_G.t3 = tap(0xe84000, 0xe87fff)   -- DMAC + AREASET
_G.t4 = tap(0xe8e000, 0xe8ffff)   -- system port
_G.t5 = tap(0xeb0000, 0xeb0fff)   -- sprite registers
_G.t6 = mem:install_write_tap(0x000400, 0x0007ff, "dram", function (o, d, m)
  if not dram then
    dram = true
    print(string.format(">>>> first write above the vector table: $%06X at PC $%06X (event %d)",
          o, cpu.state["PC"].value, n))
  end
  return d
end)
