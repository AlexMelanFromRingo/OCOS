-- /bin/shutdown.lua
require("k.log").info("shutdown", "shutdown requested")
computer.shutdown(false)
return 0
