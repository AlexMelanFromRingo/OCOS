-- /sys/lib/ui/widgets/taskbar.lua — bottom strip with open-window chips
-- and a system tray (clock, user, power menu).
--
-- Listens for `ui.taskbar.refresh` ipc events to redraw — the WM emits
-- one whenever its window list changes.
--
-- Constructor:
--   taskbar({ wm = wm_instance, user = "alex",
--             on_power = function(action) ... end,
--             on_launcher = function() ... end })

local widget = require("lib.ui.widget")
local ipc    = require("k.ipc")

local function clock_text()
  local t = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
  local h, m = math.floor(t / 3600) % 24, math.floor(t / 60) % 60
  return string.format("%02d:%02d", h, m)
end

return function(props)
  local W = widget.new("taskbar", {
    chips = {},                                    -- {x1, x2, win}

    measure = function(_, mw, _) return mw, 1 end,

    draw = function(self, buf, theme)
      local b   = self.bounds
      local bg  = (theme.taskbar and theme.taskbar.bg) or theme.palette.surface
      local fg  = (theme.taskbar and theme.taskbar.fg) or theme.palette.fg
      local acc = theme.palette.accent or 0x4FA0F0
      local muted = theme.palette.muted or 0x666666
      buf:fill(b.x, b.y, b.w, b.h, " ", fg, bg)

      local x = b.x + 1
      -- Launcher button
      buf:set(x, b.y, "[ + ]", fg, bg)
      self.chips = { { x1 = x, x2 = x + 4, kind = "launcher" } }
      x = x + 6

      local right_reserve = 16   -- " alex 14:32  ⏻ "
      local list = self.props.wm and self.props.wm:windows_for_taskbar() or {}
      for _, w in ipairs(list) do
        local label = w.title or "Window"
        if #label > 12 then label = label:sub(1, 11) .. "…" end
        local marker = w.minimised and "·" or (w.focused and "▾" or " ")
        local chip = "[" .. marker .. label .. "]"
        if x + #chip > b.x + b.w - right_reserve then break end
        local chip_fg = w.focused and 0xFFFFFF or fg
        local chip_bg = w.focused and acc or bg
        for i = 1, #chip do buf:set(x + i - 1, b.y, chip:sub(i, i), chip_fg, chip_bg) end
        self.chips[#self.chips + 1] = { x1 = x, x2 = x + #chip - 1, kind = "win", win = w.win }
        x = x + #chip + 1
      end

      -- Right side: user · clock · power
      local right = "  " .. (self.props.user or "root") .. " " .. clock_text() .. "  ⏻ "
      local rx = b.x + b.w - #right - 1
      for i = 1, #right do buf:set(rx + i, b.y, right:sub(i, i), muted, bg) end
      -- Power button
      local px = b.x + b.w - 2
      buf:set(px, b.y, "⏻", fg, bg)
      self.chips[#self.chips + 1] = { x1 = px, x2 = px, kind = "power" }
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type ~= "touch" or not self:hit(ev.x, ev.y) then return false end
      for _, c in ipairs(self.chips) do
        if ev.x >= c.x1 and ev.x <= c.x2 then
          if     c.kind == "launcher" and self.props.on_launcher then self.props.on_launcher(); return true
          elseif c.kind == "win"      and self.props.wm          then self.props.wm:click_taskbar(c.win); return true
          elseif c.kind == "power"    and self.props.on_power_menu then self.props.on_power_menu(); return true
          end
        end
      end
      return false
    end,
  }, props or {})

  -- Re-paint every minute (clock) and on wm changes.
  if props and props.wm then
    props.wm:on_changed(function() W:invalidate() end)
  end

  return W
end
