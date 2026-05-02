-- /sys/lib/sh/builtins.lua — commands that must run in the shell's own
-- context (they mutate shell state). Each handler receives:
--   words    : array of expanded argv
--   shell    : the shell state ({env, aliases, last_status, ...})
--   streams  : {stdin, stdout, stderr} for output (post-redirect)
-- and returns a numeric exit code.

local M = {}

local vfs = require("k.vfs")

local function w(streams, ...)
  for i = 1, select("#", ...) do streams.stdout:write(tostring((select(i, ...)))) end
end

function M.cd(words, shell, streams)
  local target = words[2] or shell.env.HOME or "/"
  if target:sub(1, 1) ~= "/" then target = (shell.env.PWD or "/") .. "/" .. target end
  target = vfs.canonical(target)
  if not vfs.exists(target) then
    streams.stderr:write("cd: no such directory: " .. target .. "\n")
    return 1
  end
  if not vfs.isdir(target) then
    streams.stderr:write("cd: not a directory: " .. target .. "\n")
    return 1
  end
  shell.env.PWD = target
  return 0
end

function M.pwd(_, shell, streams)
  w(streams, shell.env.PWD or "/", "\n")
  return 0
end

function M.exit(words, shell)
  shell.exit_requested = true
  shell.last_status = tonumber(words[2] or 0) or 0
  return shell.last_status
end

function M.set(words, shell, streams)
  if #words == 1 then
    local names = {}
    for k in pairs(shell.env) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do w(streams, k, "=", tostring(shell.env[k]), "\n") end
    return 0
  end
  for i = 2, #words do
    local k, v = words[i]:match("^([%w_]+)=(.*)$")
    if not k then
      streams.stderr:write("set: invalid assignment: " .. words[i] .. "\n")
      return 2
    end
    shell.env[k] = v
  end
  return 0
end

function M.unset(words, shell)
  for i = 2, #words do shell.env[words[i]] = nil end
  return 0
end

function M.export(words, shell, streams)
  -- Same effect as `set` for our shell since there is no separate exported
  -- vs unexported namespace; included for muscle-memory compatibility.
  return M.set(words, shell, streams)
end

function M.alias(words, shell, streams)
  if #words == 1 then
    local names = {}
    for k in pairs(shell.aliases) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do w(streams, "alias ", k, "='", shell.aliases[k], "'\n") end
    return 0
  end
  for i = 2, #words do
    local k, v = words[i]:match("^([%w_]+)=(.*)$")
    if not k then
      streams.stderr:write("alias: invalid form: " .. words[i] .. "\n")
      return 2
    end
    shell.aliases[k] = v
  end
  return 0
end

function M.unalias(words, shell)
  for i = 2, #words do shell.aliases[words[i]] = nil end
  return 0
end

function M.echo(words, _, streams)
  -- Built-in echo so simple redirects work even when /bin/echo is absent.
  local parts = {}
  for i = 2, #words do parts[i - 1] = words[i] end
  streams.stdout:write(table.concat(parts, " "), "\n")
  return 0
end

function M.exec(words, shell, streams)
  if #words == 1 then return 0 end
  -- exec WORD ... replaces the shell with the given external command.
  shell.exec_replacement = { words = words, streams = streams }
  return 0
end

function M.true_cmd() return 0 end
function M.false_cmd() return 1 end

M["true"]  = M.true_cmd
M["false"] = M.false_cmd

return M
