-- /sys/lib/term/tty.lua — Stream interface over the interactive console.
--
-- One TTY pair per console is enough; we expose a singleton via
-- `tty.stdin()` / `tty.stdout()` / `tty.stderr()` that the init service hands
-- to the first shell. Subprocesses can ask for fresh streams if they want
-- to render to a sub-region (the M3 compositor will use that).

local M = {}

local stream  = require("std.stream")
local console = require("lib.term.console")
local sched   = require("k.sched")

local function make_stdout(color)
  local original
  return stream.new {
    _write = function(self, s)
      if color then original = console.fg(); console.set_fg(color) end
      console.write(s)
      if color then console.set_fg(original) end
      return self
    end,
    _flush = function(self) return self end,
  }
end

local _stdin
local function get_stdin()
  if _stdin then return _stdin end
  _stdin = stream.new {
    _read = function(self, fmt_or_n)
      -- Lines are the only format the live keyboard meaningfully produces.
      if type(fmt_or_n) == "number" then
        local line = console.read_line()
        if not line then return nil end
        return line:sub(1, fmt_or_n)
      end
      return console.read_line()
    end,
  }
  return _stdin
end

function M.stdin()  return get_stdin() end
function M.stdout() return make_stdout(nil) end
function M.stderr() return make_stdout(0xFF6060) end                       -- red

return M
