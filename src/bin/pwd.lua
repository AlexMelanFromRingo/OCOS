-- /bin/pwd.lua
local _, env = ...
local term = require("lib.term.console")
term.writeln(env.PWD or "/")
return 0
