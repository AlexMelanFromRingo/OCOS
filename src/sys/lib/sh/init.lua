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
  if opts.banner then console.writeln(opts.banner) end

  local hist        = history.open(history_path(shell))
  local complete_fn = complete.for_shell(shell)

  while not shell.exit_requested do
    local accent = console.fg()
    console.set_fg(0x88FF88)
    local line = console.read_line(prompt_text(shell), {
      history      = hist,
      complete     = complete_fn,
      on_interrupt = function() return "reset" end,
    })
    console.set_fg(accent)
    if line == nil then break end
    if line ~= "" then
      M.run_string(line, shell, opts.streams)
    end
  end
  return shell.last_status
end

return M
