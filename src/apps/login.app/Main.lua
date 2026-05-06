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

-- Iterate `s` one UTF-8 codepoint at a time so glyphs like the
-- password mask "•" and the em-dashes in the hint render as one cell
-- per character instead of one cell per byte. Without this every
-- multi-byte glyph leaves N-1 garbage cells filled with the next
-- bytes' colour — the black rectangles in the screenshots.
local function each_glyph(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local b = s:byte(i)
    local len
    if     b < 0x80 then len = 1
    elseif b < 0xC0 then len = 1
    elseif b < 0xE0 then len = 2
    elseif b < 0xF0 then len = 3
    else                len = 4
    end
    if i + len - 1 > n then len = n - i + 1 end
    local g = s:sub(i, i + len - 1)
    i = i + len
    return g
  end
end
local function utf8_len(s)
  local n = 0; for _ in each_glyph(s) do n = n + 1 end; return n
end

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
    local px = b.x + (b.w - #label - 24) // 2
    local py = sy + card_h + 3
    for i = 1, #label do buf:set(px + i - 1, py, label:sub(i, i), 0xCCCCCC, 0x101820) end
    buf:fill(px + #label, py, 24, 1, " ", 0xFFFFFF, 0x000000)
    -- One glyph per password character. utf8_len(entry) covers the
    -- case where the user types Cyrillic — each codepoint is one dot.
    for i = 1, math.min(utf8_len(entry), 24) do
      buf:set(px + #label + i - 1, py, "*", 0xFFFFFF, 0x000000)
    end

    if error_msg then
      local mx = b.x + (b.w - utf8_len(error_msg)) // 2
      local col = 0
      for g in each_glyph(error_msg) do
        buf:set(mx + col, py + 2, g, 0xFF6666, 0x101820); col = col + 1
      end
    end

    -- ASCII-only hint: the OC font ships em-dash but rendering it
    -- requires the iteration to be glyph-aware, and a plain "-" is
    -- visually clearer in the cramped row anyway.
    local hint = "Tab - switch user / Enter - log in"
    local hx = b.x + (b.w - #hint) // 2
    for i = 1, #hint do
      buf:set(hx + i - 1, b.y + b.h - 2, hint:sub(i, i), 0x666666, 0x101820)
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
      if utf8_len(entry) > 0 then
        -- Drop the trailing glyph by rebuilding without the last one.
        local glyphs = {}
        for g in each_glyph(entry) do glyphs[#glyphs + 1] = g end
        glyphs[#glyphs] = nil
        entry = table.concat(glyphs)
        self:invalidate()
      end
      return true
    elseif ev.char and ev.char >= 32 then
      local ucs = _G.unicode
      local glyph = ev.char < 128 and string.char(ev.char)
        or (ucs and ucs.char and ucs.char(ev.char) or string.char(ev.char))
      entry = entry .. glyph; error_msg = nil
      self:invalidate(); return true
    end
    return true
  end,
})

picker:layout(1, 1, sw, sh)
compositor:add(picker)
compositor:invalidate()
return 0
