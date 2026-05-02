-- /bin/cd.lua
local args, env = ...
local term = require("lib.term.console")
local vfs  = require("k.vfs")

local target = args[1] or env.HOME or "/"
if target:sub(1, 1) ~= "/" then target = (env.PWD or "/") .. "/" .. target end
target = vfs.canonical(target)

if not vfs.exists(target) then term.writeln("cd: no such directory: " .. target); return 1 end
if not vfs.isdir(target) then term.writeln("cd: not a directory: " .. target); return 1 end
env.PWD = target
return 0
