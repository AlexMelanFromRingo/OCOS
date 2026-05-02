-- /bin/free.lua — memory usage via the host computer component.
local total = computer.totalMemory()
local free  = computer.freeMemory()
local used  = total - free
print(string.format("%-10s %10s %10s %10s", "", "total", "used", "free"))
print(string.format("%-10s %10d %10d %10d", "Mem", total, used, free))
return 0
