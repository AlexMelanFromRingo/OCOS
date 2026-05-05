-- /bin/repl.lua — interactive Lua REPL.
--
-- Each line is first compiled as a return-expression (so `1+2` prints `3`).
-- If that fails, the line is re-compiled as a statement. Multi-line input
-- is supported by a continuation prompt: when the parser raises
-- "<eof>" we keep reading until the chunk parses or the user blanks.

local args, env = ...
local console = require("lib.term.console")
local sched   = require("k.sched")
local inspect = require("lib.devtools.inspect")

local sandbox = setmetatable({
  -- Shared between turns so users can build state across lines.
  inspect = inspect.inspect,
  print   = print,
  io      = io,
  os      = os,
  table   = table,
  string  = string,
  math    = math,
  require = require,
}, { __index = _G })

local function try_compile(src)
  local fn = load("return " .. src, "=stdin", "t", sandbox)
  if fn then return fn end
  return load(src, "=stdin", "t", sandbox)
end

local function show(...)
  local n = select("#", ...)
  if n == 0 then return end
  local out = {}
  for i = 1, n do
    out[i] = inspect.inspect((select(i, ...)))
  end
  io.write(table.concat(out, "\t"), "\n")
end

print("OCOS REPL — Lua " .. _VERSION .. ", type `quit` or Ctrl-D to leave")

local pending = ""
while true do
  console.write(pending == "" and "> " or ">> ")
  local line = console.read_line()
  if line == nil or line == "quit" then break end

  local src = pending == "" and line or (pending .. "\n" .. line)
  local fn, err = try_compile(src)
  if fn then
    local ok, result = pcall(function() return table.pack(fn()) end)
    if ok then show(table.unpack(result, 1, result.n))
    else io.stderr:write("error: " .. tostring(result) .. "\n") end
    pending = ""
  elseif err and err:match("<eof>") then
    pending = src
  else
    io.stderr:write("error: " .. tostring(err) .. "\n")
    pending = ""
  end
end
return 0
