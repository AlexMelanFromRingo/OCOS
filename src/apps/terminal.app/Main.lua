-- /apps/terminal.app/Main.lua — GUI terminal that hosts /bin/sh.
local _, _, session = ...

local ui       = require("lib.ui")
local exec     = require("k.exec")
local sched    = require("k.sched")
local terminal = require("lib.ui.widgets.terminal")

if not (session and session.compositor) then return 1 end
local compositor = session.compositor

local term = terminal({})
local win = ui.widgets.window({
  title = "Terminal", w = 70, h = 20,
  body = term,
  on_close = function(self)
    self.visible = false
    term.close_input()
    self:invalidate()
  end,
})
win:layout(2, 3, 70, 20)
compositor:add(win)
term.state.focused = true
compositor:invalidate()

-- Spawn /bin/sh.lua wired into the terminal's streams. When the shell
-- exits naturally (the user typed `exit`) we close the window.
local sh = exec.exec("/bin/sh.lua", {}, {
  streams   = { stdin = term.stdin, stdout = term.stdout, stderr = term.stderr },
  shell_env = { PATH = "/bin", PWD = "/", HOME = "/home", USER = "root" },
  caps      = { "*" },
  name      = "sh-gui",
})
if not sh then
  term.stderr:write("terminal: cannot launch /bin/sh.lua\n")
  return 1
end
sched.spawn(function()
  sched.wait_pid(sh.id)
  win.visible = false
  win:invalidate()
  computer.pushSignal("__ui_tick")
end, { name = "terminal-watch", caps = { "*" } })

return 0
