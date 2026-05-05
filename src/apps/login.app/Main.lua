-- /apps/login.app/Main.lua — graphical login picker (multi-user).
--
-- Shown by uid before the desktop loads when /etc/passwd is non-empty.
-- Lists user accounts as cards, lets the player pick one with Tab/click
-- and types a password. On success, publishes ipc "ses.login.ok" with
-- the user record so the desktop app can launch with their environment.

local _, _, session = ...

local ui    = require("lib.ui")
local users = require("lib.auth.users")
local audit = require("lib.auth.audit")
local ipc   = require("k.ipc")
local widget = ui.widget

local compositor = session and session.compositor
if not compositor then return 0 end
local sw, sh = compositor:size()

local function listed_users()
  local names = users.list()
  if #names == 0 then names = { "root" } end
  return names
end

local USERS = listed_users()
local sel    = 1
local entry  = ""
local error_msg

local function login_ok(name)
  audit.write({ kind = "login.ok", user = name })
  ipc.publish("ses.login.ok", { user = name, rec = users.get(name) or { home="/home", caps={"*"} } })
end

local function attempt()
  local name = USERS[sel]
  if users.empty() then
    login_ok(name); return
  end
  if users.verify(name, entry) then
    login_ok(name); return
  end
  audit.write({ kind = "login.fail", user = name })
  entry = ""; error_msg = "Wrong password"
end

local picker = widget.new("login", {
  measure = function(_, mw, mh) return mw, mh end,
  draw = function(self, buf, theme)
    local b = self.bounds
    buf:fill(b.x, b.y, b.w, b.h, " ", 0xCCCCCC, 0x101820)

    local hdr = _OSVERSION or "OCOS"
    for i = 1, #hdr do
      buf:set(b.x + (b.w - #hdr) // 2 + i - 1, b.y + 2, hdr:sub(i, i), 0xCCCCFF, 0x101820)
    end

    -- User cards
    local card_w, card_h = 14, 4
    local total_w = #USERS * (card_w + 2) + 2
    local sx = b.x + (b.w - total_w) // 2
    local sy = b.y + b.h // 2 - 6
    for i, name in ipairs(USERS) do
      local x = sx + (i - 1) * (card_w + 2)
      local fg = (i == sel) and 0xFFFFFF or 0xAAAAAA
      local bg = (i == sel) and (theme.palette.accent or 0x4FA0F0) or 0x222222
      buf:fill(x, sy, card_w, card_h, " ", fg, bg)
      -- Avatar bullet
      buf:set(x + card_w // 2 - 1, sy + 1, "👤", fg, bg)
      -- Name
      local nm = name
      if #nm > card_w - 2 then nm = nm:sub(1, card_w - 3) .. "…" end
      for j = 1, #nm do
        buf:set(x + (card_w - #nm) // 2 + j - 1, sy + 2, nm:sub(j, j), fg, bg)
      end
    end

    -- Password input
    local label = "Password: "
    local mask  = string.rep("•", #entry)
    local px = b.x + (b.w - #label - 24) // 2
    local py = sy + card_h + 3
    for i = 1, #label do buf:set(px + i - 1, py, label:sub(i, i), 0xCCCCCC, 0x101820) end
    buf:fill(px + #label, py, 24, 1, " ", 0xFFFFFF, 0x000000)
    for i = 1, math.min(#mask, 24) do
      buf:set(px + #label + i - 1, py, mask:sub(i, i), 0xFFFFFF, 0x000000)
    end

    if error_msg then
      local mx = b.x + (b.w - #error_msg) // 2
      for i = 1, #error_msg do
        buf:set(mx + i - 1, py + 2, error_msg:sub(i, i), 0xFF6666, 0x101820)
      end
    end

    local hint = "Tab — switch user · Enter — log in"
    for i = 1, #hint do
      buf:set(b.x + (b.w - #hint) // 2 + i - 1, b.y + b.h - 2, hint:sub(i, i), 0x666666, 0x101820)
    end
    self.dirty = false
  end,
  on_event = function(self, ev)
    if ev.type ~= "key" or not ev.down then return false end
    if ev.code == 15 then  -- Tab
      sel = (sel % #USERS) + 1; entry = ""; error_msg = nil
      self:invalidate(); return true
    elseif ev.code == 28 then  -- Enter
      attempt(); self:invalidate(); return true
    elseif ev.code == 14 then  -- Backspace
      if #entry > 0 then entry = entry:sub(1, -2); self:invalidate() end
      return true
    elseif ev.char and ev.char >= 32 and ev.char < 127 then
      entry = entry .. string.char(ev.char); error_msg = nil
      self:invalidate(); return true
    end
    return true
  end,
})

picker:layout(1, 1, sw, sh)
compositor:add(picker)
compositor:invalidate()
return 0
