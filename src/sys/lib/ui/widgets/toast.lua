-- /sys/lib/ui/widgets/toast.lua — top-right notification stack.
--
-- Subscribes to ipc "ui.notify" — payload { title, body, level } — and
-- adds a transient toast that fades after `duration` seconds. Multiple
-- toasts stack vertically; oldest at the bottom. The widget paints
-- after everything else (it's a sibling of the desktop root drawn last)
-- so toasts are always on top.

local widget = require("lib.ui.widget")
local ipc    = require("k.ipc")
local sched  = require("k.sched")
local utf8u  = require("lib.codec.utf8")

local DEFAULT_DURATION = 4

return function(props)
  local W = widget.new("toast-stack", {
    state = { items = {} },                       -- {title, body, level, expires}

    measure = function(_, mw, mh) return mw, mh end,

    draw = function(self, buf, theme)
      local b = self.bounds
      local w = 32
      local x = b.x + b.w - w - 1
      local y = b.y + 1
      local now = computer.uptime()
      -- Drop expired before rendering so a toast disappears as soon as
      -- its time runs out, not on the next IPC event.
      local kept = {}
      for _, item in ipairs(self.state.items) do
        if item.expires > now then kept[#kept + 1] = item end
      end
      self.state.items = kept

      for _, item in ipairs(kept) do
        local level_fg = ({
          info  = theme.palette.accent or 0x4FA0F0,
          warn  = 0xFFCC66,
          error = 0xFF6666,
        })[item.level or "info"] or 0x4FA0F0
        -- Glyph-aware wrapping so cyrillic-bodied notifications wrap at
        -- the visible cell boundary instead of mid-codepoint.
        local body_lines = {}
        do
          local body = item.body or ""
          local glyphs = utf8u.chars(body)
          local i, n = 1, #glyphs
          while i <= n do
            local last = math.min(i + (w - 4) - 1, n)
            body_lines[#body_lines + 1] = table.concat(glyphs, "", i, last)
            i = last + 1
          end
        end
        local h = 2 + #body_lines
        if y + h > b.y + b.h then break end

        -- Frame
        for i = 1, h do
          buf:fill(x, y + i - 1, w, 1, " ", theme.palette.fg, 0x1F2933)
        end
        for xx = x + 1, x + w - 2 do
          buf:set(xx, y,         "─", level_fg, 0x1F2933)
          buf:set(xx, y + h - 1, "─", level_fg, 0x1F2933)
        end
        for yy = y, y + h - 1 do
          buf:set(x,         yy, "│", level_fg, 0x1F2933)
          buf:set(x + w - 1, yy, "│", level_fg, 0x1F2933)
        end
        buf:set(x,         y,         "┌", level_fg, 0x1F2933)
        buf:set(x + w - 1, y,         "┐", level_fg, 0x1F2933)
        buf:set(x,         y + h - 1, "└", level_fg, 0x1F2933)
        buf:set(x + w - 1, y + h - 1, "┘", level_fg, 0x1F2933)

        -- Title (glyph-iterate; clamp at w-4 cells, trail with "…").
        local title = item.title or "Notice"
        if utf8u.len(title) > w - 4 then title = utf8u.sub(title, 1, w - 5) .. "…" end
        do
          local col = 0
          for g in utf8u.each(title) do
            buf:set(x + 1 + col + 1, y, g, level_fg, 0x1F2933); col = col + 1
          end
        end
        -- Body
        for li, ln in ipairs(body_lines) do
          local col = 0
          for g in utf8u.each(ln) do
            buf:set(x + 1 + col + 1, y + li, g, 0xCCCCCC, 0x1F2933); col = col + 1
          end
        end

        y = y + h + 1
      end
      self.dirty = false
    end,
  }, props or {})

  -- Subscribe to ipc.ui.notify and add a toast each time.
  ipc.subscribe("ui.notify", function(p)
    p = p or {}
    table.insert(W.state.items, 1, {
      title = p.title or "Notice",
      body  = p.body  or "",
      level = p.level or "info",
      expires = computer.uptime() + (p.duration or DEFAULT_DURATION),
    })
    -- Keep the stack bounded.
    while #W.state.items > 5 do table.remove(W.state.items) end
    W:invalidate()
    computer.pushSignal("__ui_tick")
  end)

  -- Periodic re-paint so toasts disappear without external events.
  sched.spawn(function()
    while true do
      sched.sleep(1)
      if #W.state.items > 0 then
        W:invalidate()
        computer.pushSignal("__ui_tick")
      end
    end
  end, { name = "toast-tick", caps = { "*" } })

  return W
end
