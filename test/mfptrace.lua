-- Which MFP registers does exbios program, and when?  MFP timers are the one
-- periodic source in the machine we have not accounted for, and our POST's
-- RESET instruction stops all four.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local names = {[9]="TACR",[11]="TBCR",[13]="TCDCR",[15]="TADR",[16]="TBDR",
               [17]="TCDR",[18]="TDDR",[19]="SCR",[20]="UCR",[21]="RSR",
               [22]="TSR",[23]="UDR",[0]="GPIP",[3]="IERA",[4]="IERB",
               [9]="IMRA",[10]="IMRB",[11]="VR"}
local n = 0
_G.m = mem:install_write_tap(0xe88000, 0xe89fff, "mfp", function (o, d, m)
  n = n + 1
  if n <= 30 then
    local reg = (o - 0xe88001) // 2
    print(string.format("MFP reg %2d %-6s $%06X <- %02X   PC $%06X",
          reg, names[reg] or "", o, d & 0xff, cpu.state["PC"].value))
  end
  return d
end)
