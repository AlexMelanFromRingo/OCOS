-- /sys/lib/devtools/repl.lua — Lua REPL loop and shared sandbox.
--
-- Used by /bin/repl (interactive) and /bin/lua (script + REPL fallback)
-- so they expose the same global table to user code.

local M = {}

local console = require("lib.term.console")
local inspect = require("lib.devtools.inspect")

function M.new_sandbox(extras)
  -- The sandbox shares state across REPL turns and across `lua` invocations
  -- within the same process. _G is the fallback for everything else.
  local s = setmetatable({
    inspect = inspect.inspect,
    print   = print,
    io      = io,
    os      = os,
    table   = table,
    string  = string,
    math    = math,
    require = require,
  }, { __index = _G })
  if extras then
    for k, v in pairs(extras) do s[k] = v end
  end
  return s
end

local function try_compile(src, sandbox)
  local fn = load("return " .. src, "=stdin", "t", sandbox)
  if fn then return fn end
  return load(src, "=stdin", "t", sandbox)
end

local function show(...)
  local n = select("#", ...)
  if n == 0 then return end
  local out = {}
  for i = 1, n do out[i] = inspect.inspect((select(i, ...))) end
  io.write(table.concat(out, "\t"), "\n")
end

function M.loop(opts)
  opts = opts or {}
  local sandbox = opts.sandbox or M.new_sandbox()
  console.writeln(opts.banner or
    ("OCOS REPL — Lua " .. _VERSION .. ", type `quit` or Ctrl-D to leave"))

  local pending = ""
  while true do
    console.write(pending == "" and "> " or ">> ")
    local line = console.read_line()
    if line == nil or line == "quit" then break end

    local src = pending == "" and line or (pending .. "\n" .. line)
    local fn, err = try_compile(src, sandbox)
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
end

return M
