-- /sys/k/exec.lua — "load this script as a new sandboxed process".
--
-- Builds a per-process Lua environment whose `io`, `print`, and `os.getenv`
-- are bound to the process's own streams and shell environment, then
-- `load`s the script with that env and hands it to the scheduler.

local M = {}

local vfs   = require("k.vfs")
local sched = require("k.sched")
local io_b  = require("std.io")

local function build_env(streams, shell_env, parent_env)
  -- streams must already include {stdin, stdout, stderr}. shell_env is the
  -- POSIX-shell-style {PATH=...,PWD=...,USER=...} table.
  local proc_io = io_b.bind(streams)
  local print_fn = io_b.print_for(proc_io)

  local os_proxy = setmetatable({
    getenv = function(name) return shell_env and shell_env[name] end,
    setenv = function(name, value)
      if shell_env then shell_env[name] = value end
    end,
  }, { __index = _G.os })

  local env = setmetatable({
    io       = proc_io,
    print    = print_fn,
    os       = os_proxy,
    _SHELL   = shell_env,
  }, { __index = parent_env or _G })
  env._ENV = env
  return env, proc_io
end

function M.exec(path, args, opts)
  -- opts: {streams, shell_env, caps, name, parent}
  opts = opts or {}
  args = args or {}
  local src, err = vfs.read_all(path)
  if not src then return nil, err end
  local env, proc_io = build_env(opts.streams or {}, opts.shell_env, opts.parent_env)
  local fn, lerr = load(src, "=" .. path, "t", env)
  if not fn then return nil, lerr end

  local proc_opts = {
    name      = opts.name or path:match("([^/]+)$") or path,
    cmdline   = opts.cmdline or path,
    parent    = opts.parent,
    caps      = opts.caps,
    io        = proc_io,
    shell_env = opts.shell_env,
    env       = env,
  }
  local body = function() return fn(args, env._SHELL or {}) end
  return sched.spawn(body, proc_opts)
end

M.build_env = build_env
return M
