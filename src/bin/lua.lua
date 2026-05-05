-- /bin/lua — run a Lua script, or drop into the REPL when no file is given.
-- Usage:
--   lua                        interactive REPL
--   lua FILE [arg...]          load FILE and call it; arg[0]=FILE, arg[1..]=rest
--   lua -e 'chunk' [arg...]    evaluate `chunk` with the trailing args
--
-- The script runs in the same shared sandbox as the REPL.

local args, env = ...
local vfs  = require("k.vfs")
local repl = require("lib.devtools.repl")

local function err(msg) io.stderr:write("lua: " .. msg .. "\n") end

if #args == 0 then return repl.loop() end

local sandbox = repl.new_sandbox()

local function run_chunk(src, name, script_args)
  sandbox.arg = script_args
  local fn, e = load(src, name, "t", sandbox)
  if not fn then err(tostring(e)); return 1 end
  local ok, ret = pcall(fn)
  if not ok then err(tostring(ret)); return 1 end
  if type(ret) == "number" then return math.floor(ret) end
  return 0
end

if args[1] == "-e" then
  if not args[2] then err("-e requires an argument"); return 2 end
  local script_args = { [0] = "=(command line)" }
  for i = 3, #args do script_args[i - 2] = args[i] end
  return run_chunk(args[2], "=(-e)", script_args)
end

local path = args[1]
if path:sub(1, 1) ~= "/" then
  local pwd = (env and env.PWD) or "/"
  path = vfs.canonical(pwd .. "/" .. path)
end

if not vfs.exists(path) then err("'" .. path .. "': No such file"); return 1 end
local src, e = vfs.read_all(path)
if not src then err("'" .. path .. "': " .. tostring(e)); return 1 end

local script_args = { [0] = path }
for i = 2, #args do script_args[i - 1] = args[i] end
return run_chunk(src, "=" .. path, script_args)
