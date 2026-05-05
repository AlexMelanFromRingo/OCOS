-- /apps/terminal.app/Main.lua — GUI terminal that hosts /bin/sh.
local _, env, session = ...

local ui       = require("lib.ui")
local exec     = require("k.exec")
local sched    = require("k.sched")
local terminal = require("lib.ui.widgets.terminal")

if not (session and session.compositor and session.wm) then return 1 end

local term = terminal({})
local user = (env and env.USER) or "root"
local home = (env and env.HOME) or "/home"

local win = session.wm:open{
  title = "Terminal — " .. user, body = term, w = 70, h = 18, x = 4, y = 3,
}
term.state.focused = true

local sh = exec.exec("/bin/sh.lua", {}, {
  streams   = { stdin = term.stdin, stdout = term.stdout, stderr = term.stderr },
  shell_env = { PATH = "/bin", PWD = home, HOME = home, USER = user },
  caps      = { "*" },
  name      = "sh-gui",
})
if not sh then
  term.stderr:write("terminal: cannot launch /bin/sh.lua\n")
  return 1
end

sched.spawn(function()
  sched.wait_pid(sh.id)
  if session.wm and win then session.wm:close(win) end
  computer.pushSignal("__ui_tick")
end, { name = "terminal-watch", caps = { "*" } })

return 0
