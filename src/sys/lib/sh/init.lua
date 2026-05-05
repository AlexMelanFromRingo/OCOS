-- /sys/lib/sh/init.lua — interactive shell entry point.
--
-- Provides:
--   sh.repl(opts) — runs an interactive read-eval-print loop on the given
--                   streams; returns the last status when "exit" is invoked.
--   sh.run_string(src, shell, streams) — single-shot evaluator used by
--                                        rcfiles and tests.

local M = {}

local console  = require("lib.term.console")
local lexer    = require("lib.sh.lexer")
local parser   = require("lib.sh.parser")
local runner   = require("lib.sh.runner")
local history  = require("lib.sh.history")
local complete = require("lib.sh.complete")

local function new_shell(env)
  return {
    env         = env or { PATH = "/bin", PWD = "/", HOME = "/home", USER = "root" },
    aliases     = {},
    last_status = 0,
  }
end

function M.run_string(src, shell, streams)
  local tokens, lex_err = lexer.lex(src)
  if not tokens then streams.stderr:write("sh: " .. lex_err .. "\n"); return 2 end
  if #tokens == 0 then return shell.last_status or 0 end
  local ast, parse_err = parser.parse(tokens)
  if not ast then streams.stderr:write("sh: " .. parse_err .. "\n"); return 2 end
  local ok, code = xpcall(function() return runner.run(ast, shell, streams) end,
    function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
  if not ok then streams.stderr:write("sh: " .. tostring(code) .. "\n"); return 1 end
  return code
end

local function prompt_text(shell)
  return string.format("[%s] %s$ ", shell.env.PWD or "/", shell.env.USER or "")
end

local function history_path(shell)
  local home = shell.env.HOME or "/home"
  return home .. "/.sh_history"
end

function M.repl(opts)
  opts = opts or {}
  local shell = new_shell(opts.env)
  shell.caps = opts.caps
  local streams = opts.streams
  -- TTY shells paint via the console module directly (line editor with
  -- history, tab completion, caret). Non-TTY shells (the GUI terminal,
  -- pipelines) round-trip through the stream pair the caller supplied
  -- — the terminal widget owns its own input area and a console-direct
  -- prompt would land outside the window on the bare wallpaper.
  local is_tty = streams and streams.stdout and streams.stdout._isatty

  if opts.banner then
    if is_tty then console.writeln(opts.banner)
    elseif streams and streams.stdout then streams.stdout:write(opts.banner .. "\n") end
  end

  local hist        = is_tty and history.open(history_path(shell)) or nil
  local complete_fn = is_tty and complete.for_shell(shell) or nil

  while not shell.exit_requested do
    local line
    if is_tty then
      local accent = console.fg()
      console.set_fg(0x88FF88)
      line = console.read_line(prompt_text(shell), {
        history      = hist,
        complete     = complete_fn,
        on_interrupt = function() return "reset" end,
      })
      console.set_fg(accent)
    else
      streams.stdout:write(prompt_text(shell))
      line = streams.stdin:read("l")
    end
    if line == nil then break end
    if line ~= "" then
      M.run_string(line, shell, streams)
    end
  end
  return shell.last_status
end

return M
