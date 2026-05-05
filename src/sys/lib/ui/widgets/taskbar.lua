-- /sys/lib/ui/widgets/taskbar.lua — bottom strip with launcher,
-- open-window chips and a system tray (user · clock · power).
--
-- Painted with hard-contrast colours so it never gets lost on the
-- wallpaper, and uses ASCII-only glyphs so the OC font always
-- renders both buttons. The launcher and power buttons are coloured
-- pills (green and red) the user can spot at a glance.

local widget = require("lib.ui.widget")

local function clock_text()
  local t = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
  local h, m = math.floor(t / 3600) % 24, math.floor(t / 60) % 60
  return string.format("%02d:%02d", h, m)
end

local TB_BG = 0x1F2933                            -- explicit dark blue-grey
local TB_FG = 0xE6E6E6

return function(props)
  local W = widget.new("taskbar", {
    chips = {},

    measure = function(_, mw, _) return mw, 1 end,

    draw = function(self, buf, theme)
      local b   = self.bounds
      local acc = theme.palette.accent or 0x4F8AF0
      buf:fill(b.x, b.y, b.w, b.h, " ", TB_FG, TB_BG)

      -- Launcher pill (green) at the very left.
      local lab = " APPS "
      for i = 1, #lab do buf:set(b.x + i, b.y, lab:sub(i, i), 0xFFFFFF, 0x4CAF50) end
      self.chips = { { x1 = b.x + 1, x2 = b.x + #lab, kind = "launcher" } }
      local x = b.x + #lab + 2

      -- Open-window chips
      local right_reserve = 18   -- room for "  user 14:32  POWR"
      local list = self.props.wm and self.props.wm:windows_for_taskbar() or {}
      for _, w in ipairs(list) do
        local label = w.title or "Window"
        if #label > 12 then label = label:sub(1, 11) .. "…" end
        local marker = w.minimised and "_" or (w.focused and ">" or " ")
        local chip = " " .. marker .. label .. " "
        if x + #chip > b.x + b.w - right_reserve then break end
        local chip_fg = w.focused and 0xFFFFFF or TB_FG
        local chip_bg = w.focused and acc or 0x2A3340
        for i = 1, #chip do buf:set(x + i - 1, b.y, chip:sub(i, i), chip_fg, chip_bg) end
        self.chips[#self.chips + 1] = { x1 = x, x2 = x + #chip - 1, kind = "win", win = w.win }
        x = x + #chip + 1
      end

      -- Right side: user, clock, power pill (red).
      local user_clock = " " .. (self.props.user or "root") .. "  " .. clock_text() .. " "
      local pwr  = " POWR "
      local px   = b.x + b.w - #pwr
      local ucx  = px - #user_clock
      for i = 1, #user_clock do
        buf:set(ucx + i - 1, b.y, user_clock:sub(i, i), TB_FG, TB_BG)
      end
      for i = 1, #pwr do
        buf:set(px + i - 1, b.y, pwr:sub(i, i), 0xFFFFFF, 0xCC4444)
      end
      self.chips[#self.chips + 1] = { x1 = px, x2 = px + #pwr - 1, kind = "power" }
      self.dirty = false
    end,

    on_event = function(self, ev)
      if ev.type ~= "touch" or not self:hit(ev.x, ev.y) then return false end
      for _, c in ipairs(self.chips) do
        if ev.x >= c.x1 and ev.x <= c.x2 then
          if     c.kind == "launcher" and self.props.on_launcher    then self.props.on_launcher();    return true
          elseif c.kind == "win"      and self.props.wm             then self.props.wm:click_taskbar(c.win); return true
          elseif c.kind == "power"    and self.props.on_power_menu  then self.props.on_power_menu();  return true
          end
        end
      end
      return false
    end,
  }, props or {})

  if props and props.wm then
    props.wm:on_changed(function() W:invalidate() end)
  end
  return W
end
