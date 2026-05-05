-- /apps/lock.app/Main.lua — lock screen overlay.
--
-- Opens a fullscreen, undecorated, modal window over everything else.
-- Asks for the current user's password and stays put until the right
-- one is typed (or ESC if /etc/passwd is empty — there's no secret to
-- check then).

local _, env, session = ...

local ui    = require("lib.ui")
local users = require("lib.auth.users")
local widget = ui.widget

local compositor = session and session.compositor
local wm = session and session.wm
if not (compositor and wm) then return 0 end

local sw, sh = compositor:size()
local user = (env and env.USER) or "root"
local entry = ""

local lock = widget.new("lockscreen", {
  measure = function(_, mw, mh) return mw, mh end,
  draw = function(self, buf, theme)
    local b = self.bounds
    local fg = theme.palette.fg
    buf:fill(b.x, b.y, b.w, b.h, " ", fg, 0x000000)
    local mid_y = b.y + b.h / 2
    local title = "🔒  OCOS — locked as " .. user
    local prompt = "Password: " .. string.rep("•", #entry)
    local cx = b.x + (b.w - #title) // 2
    for i = 1, #title do buf:set(cx + i - 1, mid_y - 2, title:sub(i, i), 0xCCCCFF, 0x000000) end
    cx = b.x + (b.w - #prompt) // 2
    for i = 1, #prompt do buf:set(cx + i - 1, mid_y, prompt:sub(i, i), 0xFFFFFF, 0x000000) end
    self.dirty = false
  end,
  on_event = function(self, ev)
    if ev.type ~= "key" or not ev.down then return false end
    if ev.code == 28 then
      if users.empty() or users.verify(user, entry) then
        wm:close(self.win)
      else
        entry = ""; self:invalidate()
      end
      return true
    end
    if ev.code == 14 and #entry > 0 then
      entry = entry:sub(1, -2); self:invalidate(); return true
    end
    if ev.char and ev.char >= 32 and ev.char < 127 then
      entry = entry .. string.char(ev.char); self:invalidate(); return true
    end
    return true                                   -- swallow everything
  end,
})

local win = wm:open{
  title = "Lock", body = lock,
  x = 1, y = 1, w = sw, h = sh,
  closable = false, minimisable = false, maximisable = false, resizable = false,
}
lock.win = win                                    -- back-ref so on_event can close
return 0
