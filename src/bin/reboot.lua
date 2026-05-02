-- /bin/reboot.lua
require("k.log").info("shutdown", "reboot requested")
computer.shutdown(true)
return 0
