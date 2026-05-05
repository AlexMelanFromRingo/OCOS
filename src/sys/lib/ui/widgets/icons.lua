-- /sys/lib/ui/widgets/icons.lua — desktop icons grid with paged scroll.
--
-- Reads ~/Desktop/ and lays files / dirs out as 12-cell-wide tiles
-- arranged in pages. Click a tile to open (dirs → Files app, .lua/.txt
-- → Edit, others → notify "no handler"). PgUp / PgDn or ◀ / ▶ buttons
-- in the top-right switch pages. Right-click on empty space → context
-- menu (placeholder for now).

local widget = require("lib.ui.widget")
local vfs    = require("k.vfs")
local ipc    = require("k.ipc")

local TILE_W, TILE_H = 12, 4

local function classify(path, name)
  local ext = name:match("%.([^.]+)$")
  ext = ext and ext:lower()
  if vfs.isdir(path) then return "dir", "📁", 0x4FA0F0 end
  if ext == "lua" then return "code", "📄", 0x66DD66 end
  if ext == "txt" or ext == "md" then return "text", "📄", 0xCCCCCC end
  if ext == "cfg" or ext == "ini" then return "cfg", "⚙",  0xE0C040 end
  if ext == "png" or ext == "ocif" or ext == "ocbm" then return "image", "🖼", 0xCC66CC end
  if ext == "ocpkg" or ext == "tar" then return "archive", "📦", 0xE05050 end
  return "file", "📄", 0xCCCCCC
end

local function open_via_session(session, path, kind)
  if kind == "dir" then
    -- Re-launch Files app. Pass nothing for now; Files always opens at $HOME.
    local fn = load(vfs.read_all("/apps/files.app/Main.lua"), "=files", "t", _G)
    if fn then pcall(fn, { path }, { HOME = path }, session) end
    return
  end
  if kind == "code" or kind == "text" or kind == "cfg" then
    local fn = load(vfs.read_all("/apps/edit.app/Main.lua"), "=edit", "t", _G)
    if fn then pcall(fn, { path }, {}, session) end
    return
  end
  ipc.publish("ui.notify", { title = "Desktop", body = "No handler for " .. path, level = "warn" })
end

return function(props)
  -- props: { path = "/home/<user>/Desktop", session = session }
  local W = widget.new("icons", {
    state = { entries = {}, page = 0, hits = {} },

    refresh = function(self)
      local out = {}
      local lst = vfs.list(self.props.path) or {}
      table.sort(lst)
      for _, n in ipairs(lst) do
        local clean = n:gsub("/$", "")
        local full = self.props.path .. "/" .. clean
        local kind, glyph, fg = classify(full, clean)
        out[#out + 1] = { name = clean, path = full, kind = kind, glyph = glyph, fg = fg }
      end
      self.state.entries = out
      self.state.page = 0
      self:invalidate()
    end,

    measure = function(_, mw, mh) return mw, mh end,

    draw = function(self, buf, theme)
      local b = self.bounds
      buf:fill(b.x, b.y, b.w, b.h, " ", theme.palette.fg, theme.palette.bg)

      local cols = math.max(1, b.w // TILE_W)
      local rows = math.max(1, b.h // TILE_H)
      local per_page = cols * rows
      local total = #self.state.entries
      local pages = math.max(1, math.ceil(total / per_page))
      if self.state.page >= pages then self.state.page = pages - 1 end

      self.state.hits = {}

      local first = self.state.page * per_page + 1
      for i = 0, per_page - 1 do
        local entry = self.state.entries[first + i]
        if not entry then break end
        local r = i // cols
        local c = i %  cols
        local x = b.x + c * TILE_W
        local y = b.y + r * TILE_H

        -- Glyph centred.
        buf:set(x + TILE_W // 2 - 1, y + 1, entry.glyph, entry.fg, theme.palette.bg)
        -- Label centred, truncated.
        local label = entry.name
        if #label > TILE_W - 1 then label = label:sub(1, TILE_W - 2) .. "…" end
        local lx = x + (TILE_W - #label) // 2
        for j = 1, #label do
          buf:set(lx + j - 1, y + 2, label:sub(j, j), theme.palette.fg, theme.palette.bg)
        end
        self.state.hits[#self.state.hits + 1] = {
          x1 = x, y1 = y, x2 = x + TILE_W - 1, y2 = y + TILE_H - 1,
          entry = entry,
        }
      end

      -- Page indicator + arrows top-right.
      if pages > 1 then
        local pg = string.format("page %d/%d", self.state.page + 1, pages)
        for i = 1, #pg do
          buf:set(b.x + b.w - #pg - 6 + i, b.y, pg:sub(i, i), theme.palette.muted or 0x888888, theme.palette.bg)
        end
        buf:set(b.x + b.w - 4, b.y, "◀", theme.palette.fg, theme.palette.bg)
        buf:set(b.x + b.w - 2, b.y, "▶", theme.palette.fg, theme.palette.bg)
        self.state.prev_x, self.state.next_x, self.state.arrows_y = b.x + b.w - 4, b.x + b.w - 2, b.y
      else
        self.state.prev_x, self.state.next_x = nil, nil
      end
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type == "touch" and self:hit(ev.x, ev.y) then
        if self.state.prev_x and ev.y == self.state.arrows_y then
          if ev.x == self.state.prev_x and self.state.page > 0 then
            self.state.page = self.state.page - 1; self:invalidate(); return true
          end
          if ev.x == self.state.next_x then
            self.state.page = self.state.page + 1; self:invalidate(); return true
          end
        end
        for _, h in ipairs(self.state.hits) do
          if ev.x >= h.x1 and ev.x <= h.x2 and ev.y >= h.y1 and ev.y <= h.y2 then
            open_via_session(self.props.session, h.entry.path, h.entry.kind)
            return true
          end
        end
        return false
      elseif ev.type == "key" and ev.down then
        if ev.code == 201 and self.state.page > 0 then  -- PgUp
          self.state.page = self.state.page - 1; self:invalidate(); return true
        elseif ev.code == 209 then  -- PgDn
          self.state.page = self.state.page + 1; self:invalidate(); return true
        end
      end
      return false
    end,
  }, props or {})

  W:refresh()
  return W
end
