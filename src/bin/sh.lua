-- /bin/sh.lua — micro-shell for M1.
-- Tokeniser is intentionally tiny: split by whitespace, support double-quoted
-- segments, expand $VAR. M2 will replace this with a real pipeline shell.

local sched = require("k.sched")
local term  = require("lib.term.console")
local vfs   = require("k.vfs")
local log   = require("k.log")

_G._SHELL_ENV = _G._SHELL_ENV or { PATH = "/bin", PWD = "/", HOME = "/home", USER = "root" }
local env = _G._SHELL_ENV

local function tokenise(line)
  local tokens, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == " " or c == "\t" then i = i + 1
    elseif c == '"' then
      local j = line:find('"', i + 1, true)
      if not j then return nil, "unterminated quote" end
      tokens[#tokens + 1] = line:sub(i + 1, j - 1)
      i = j + 1
    else
      local j = line:find("[ \t]", i)
      tokens[#tokens + 1] = line:sub(i, (j or n + 1) - 1)
      i = j or (n + 1)
    end
  end
  return tokens
end

local function expand(tokens)
  for k, t in ipairs(tokens) do
    tokens[k] = (t:gsub("%$([%w_]+)", function(name) return env[name] or "" end))
  end
  return tokens
end

local function resolve_command(name)
  if name:find("/", 1, true) then return name end
  for dir in env.PATH:gmatch("[^:]+") do
    local candidate = dir .. "/" .. name .. ".lua"
    if vfs.exists(candidate) then return candidate end
    local plain = dir .. "/" .. name
    if vfs.exists(plain) then return plain end
  end
  return nil
end

local function run_command(tokens)
  local name = tokens[1]
  local path = resolve_command(name)
  if not path then term.writeln("sh: command not found: " .. name); return 127 end
  local src, err = vfs.read_all(path)
  if not src then term.writeln("sh: cannot read " .. path .. ": " .. tostring(err)); return 1 end
  local fn, lerr = load(src, "=" .. path, "t", _G)
  if not fn then term.writeln("sh: load error: " .. tostring(lerr)); return 1 end
  local args = {}
  for i = 2, #tokens do args[#args + 1] = tokens[i] end
  local ok, ret = xpcall(function() return fn(args, env) end, function(e)
    return tostring(e) .. "\n" .. debug.traceback("", 2)
  end)
  if not ok then
    term.writeln("sh: " .. tostring(ret))
    log.error("sh", "command crashed: " .. tostring(ret))
    return 1
  end
  return tonumber(ret) or 0
end

term.writeln("ocsh — type `help` to list commands, `exit` to leave")

while true do
  term.set_fg(0x88FF88); term.write("[" .. env.PWD .. "] $ "); term.set_fg(0xCCCCCC)
  local line = term.read_line()
  if not line then break end
  if line ~= "" then
    local tokens, terr = tokenise(line)
    if not tokens then term.writeln("sh: " .. terr)
    else
      tokens = expand(tokens)
      if tokens[1] == "exit" then break end
      run_command(tokens)
    end
  end
end
sched.exit(0)
