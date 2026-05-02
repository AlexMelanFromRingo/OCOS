-- /bin/echo.lua
local args = ...
local term = require("lib.term.console")
term.writeln(table.concat(args, " "))
return 0
