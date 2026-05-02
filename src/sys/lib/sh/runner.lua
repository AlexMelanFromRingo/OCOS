-- /sys/lib/sh/runner.lua — executes a parsed shell list.

local M = {}

local sched   = require("k.sched")
local exec_k  = require("k.exec")
local vfs     = require("k.vfs")
local pipe    = require("std.pipe")
local fstream = require("std.fstream")
local builtins = require("lib.sh.builtins")
local lexer    = require("lib.sh.lexer")

local function expand_parts(parts, shell)
  local segs = {}
  for _, p in ipairs(parts) do
    if p.kind == "lit" then segs[#segs + 1] = p.value
    elseif p.kind == "var" then
      local v
      if p.name == "?" then v = tostring(shell.last_status or 0)
      else v = shell.env[p.name] end
      segs[#segs + 1] = v ~= nil and tostring(v) or ""
    end
  end
  return table.concat(segs)
end

local function expand_words(words, shell)
  local out = {}
  for _, w in ipairs(words) do out[#out + 1] = expand_parts(w, shell) end
  return out
end

local function apply_alias(words, shell)
  if #words == 0 then return words end
  local seen = {}
  while shell.aliases[words[1]] and not seen[words[1]] do
    seen[words[1]] = true
    local toks = lexer.lex(shell.aliases[words[1]])
    if not toks or #toks == 0 then break end
    local replacement = {}
    for _, t in ipairs(toks) do
      if t.type == "word" then replacement[#replacement + 1] = expand_parts(t.parts, shell) end
    end
    if #replacement == 0 then break end
    table.remove(words, 1)
    for i = #replacement, 1, -1 do table.insert(words, 1, replacement[i]) end
  end
  return words
end

local function resolve_external(name, path_var)
  if name:find("/", 1, true) then
    return vfs.exists(name) and name or nil
  end
  for dir in (path_var or "/bin"):gmatch("[^:]+") do
    local cand = dir .. "/" .. name .. ".lua"
    if vfs.exists(cand) then return cand end
    local plain = dir .. "/" .. name
    if vfs.exists(plain) then return plain end
  end
  return nil
end

local function open_redirects(redirects, base, shell)
  -- Returns the post-redirect streams plus a list of files we opened (the
  -- caller closes those after the child exits).
  local s = { stdin = base.stdin, stdout = base.stdout, stderr = base.stderr }
  local opened = {}
  for _, r in ipairs(redirects) do
    local target = expand_parts(r.target, shell)
    local mode = r.op == ">" and "w" or r.op == ">>" and "a" or r.op == "<" and "r" or "w"
    local strm, err = fstream.open(target, mode)
    if not strm then return nil, "redirect: " .. tostring(err), opened end
    opened[#opened + 1] = strm
    if     r.op == ">"  or r.op == ">>" then s.stdout = strm
    elseif r.op == "<"                  then s.stdin  = strm
    elseif r.op == "2>"                 then s.stderr = strm end
  end
  return s, nil, opened
end

local function close_each(streams)
  for _, s in ipairs(streams) do pcall(s.close, s) end
end

local function spawn_for(words, shell, streams)
  -- Decide whether to run the command as a builtin or external. Returns the
  -- spawned process (always — even builtins are spawned so a pipeline stage
  -- always exits cleanly even if the builtin yields on its streams).
  local handler = builtins[words[1]]
  if handler then
    local body = function() return handler(words, shell, streams) end
    return sched.spawn(body, {
      name      = words[1],
      cmdline   = table.concat(words, " "),
      io        = streams,
      shell_env = shell.env,
      caps      = shell.caps,
    })
  end
  local target = resolve_external(words[1], shell.env.PATH)
  if not target then
    streams.stderr:write("sh: command not found: " .. words[1] .. "\n")
    return nil
  end
  local args = {}
  for i = 2, #words do args[i - 1] = words[i] end
  local p, err = exec_k.exec(target, args, {
    streams   = streams,
    shell_env = shell.env,
    cmdline   = table.concat(words, " "),
    name      = words[1],
    caps      = shell.caps,
  })
  if not p then
    streams.stderr:write("sh: cannot exec " .. target .. ": " .. tostring(err) .. "\n")
    return nil
  end
  return p
end

local function run_command_inline(cmd, shell, base)
  -- A single command with no pipeline siblings. Builtins run in the shell's
  -- own context so cd / set / exit can mutate state. Externals fork.
  local words = apply_alias(expand_words(cmd.words, shell), shell)
  if #words == 0 then return 0 end

  local streams, err, opened = open_redirects(cmd.redirects, base, shell)
  if not streams then base.stderr:write(err .. "\n"); return 1 end

  local handler = builtins[words[1]]
  local rc
  if handler then
    rc = handler(words, shell, streams) or 0
  else
    local p = spawn_for(words, shell, streams)
    if not p then close_each(opened); return 127 end
    local res = sched.wait_pid(p.id)
    rc = res and res.code or 1
  end
  close_each(opened)
  return rc
end

local function run_pipeline(pipeline, shell, base)
  if #pipeline.commands == 1 then
    return run_command_inline(pipeline.commands[1], shell, base)
  end

  local n = #pipeline.commands
  local pipes = {}                                 -- pipes[i] = {read, write}
  for i = 1, n - 1 do
    local r, w = pipe.new(); pipes[i] = { r, w }
  end

  local entries = {}                               -- {proc, opened, close_on_exit}
  for i, cmd in ipairs(pipeline.commands) do
    local stdin  = i == 1 and base.stdin  or pipes[i - 1][1]
    local stdout = i == n and base.stdout or pipes[i][2]
    local s, err, opened = open_redirects(cmd.redirects, {
      stdin = stdin, stdout = stdout, stderr = base.stderr,
    }, shell)
    if not s then base.stderr:write(err .. "\n") else
      local words = apply_alias(expand_words(cmd.words, shell), shell)
      if #words > 0 then
        local p = spawn_for(words, shell, s)
        if p then
          -- When this stage exits, close the write end of the pipe it owned
          -- so the next stage sees EOF and exits in turn.
          local close_on_exit = {}
          if i < n then close_on_exit[#close_on_exit + 1] = pipes[i][2] end
          for _, o in ipairs(opened) do close_on_exit[#close_on_exit + 1] = o end
          entries[#entries + 1] = { proc = p, close_on_exit = close_on_exit }
        else
          close_each(opened)
        end
      end
    end
  end

  local last = 0
  for _, e in ipairs(entries) do
    local res = sched.wait_pid(e.proc.id)
    if res then last = res.code end
    close_each(e.close_on_exit)
  end
  -- Drain any read ends still open (possible if a stage failed to spawn).
  for _, p in ipairs(pipes) do pcall(p[1].close, p[1]) end
  return last
end

function M.run(list, shell, streams)
  local last = shell.last_status or 0
  for i, item in ipairs(list.items) do
    local prev_op = i == 1 and "end" or list.items[i - 1].op
    local skip = (prev_op == "and" and last ~= 0) or (prev_op == "or" and last == 0)
    if not skip then
      last = run_pipeline(item.pipeline, shell, streams)
      shell.last_status = last
    end
  end
  return last
end

return M
