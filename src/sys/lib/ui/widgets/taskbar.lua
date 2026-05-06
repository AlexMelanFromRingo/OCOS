-- /sys/lib/ui/widgets/taskbar.lua — bottom strip with launcher,
-- open-window chips and a system tray (user · clock · power).
--
-- Painted with hard-contrast colours so it never gets lost on the
-- wallpaper, and uses ASCII-only glyphs so the OC font always
-- renders both buttons. The launcher and power buttons are coloured
-- pills (green and red) the user can spot at a glance.

local widget = require("lib.ui.widget")
local lang   = require("lib.lang")
local utf8u  = require("lib.codec.utf8")

local vfs_for_time = require("k.vfs")
local function clock_text()
  local t = math.floor((computer.realTime and computer.realTime()) or computer.uptime())
  -- Apply the user-set offset from /etc/time.cfg. Re-read every tick;
  -- it's a few-byte file so the cost is irrelevant.
  if vfs_for_time.exists("/etc/time.cfg") then
    local fn = load(vfs_for_time.read_all("/etc/time.cfg") or "", "=time.cfg", "t", {})
    if fn then
      local ok, cfg = pcall(fn)
      if ok and type(cfg) == "table" and tonumber(cfg.offset) then
        t = t + cfg.offset
      end
    end
  end
  t = t % 86400
  local h, m = math.floor(t / 3600), math.floor(t / 60) % 60
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

      -- Paint a string as one cell per glyph; multi-byte chars (like
      -- the cyrillic in localized labels) used to corrupt the chip
      -- cells when iterated byte-by-byte.
      local function paint(x0, str, fg, bg)
        local i = 0
        for g in utf8u.each(str) do
          buf:set(x0 + i, b.y, g, fg, bg); i = i + 1
        end
        return i                                     -- glyphs painted
      end

      -- Launcher pill (green) at the very left.
      local lab = " " .. lang.t("bar.apps") .. " "
      local lab_w = paint(b.x + 1, lab, 0xFFFFFF, 0x4CAF50)
      self.chips = { { x1 = b.x + 1, x2 = b.x + lab_w, kind = "launcher" } }
      local x = b.x + lab_w + 2

      -- Open-window chips. Right-reserve room for "  user 14:32  POWR".
      local right_reserve = 18
      local list = self.props.wm and self.props.wm:windows_for_taskbar() or {}
      for _, w in ipairs(list) do
        -- Strip any " - <path>" suffix the app baked into its title:
        -- the chip is too narrow for paths and the user only needs the
        -- app name to recognise the window.
        local label = w.title or "Window"
        local sep = label:find(" %- ")
        if sep then label = label:sub(1, sep - 1) end
        if utf8u.len(label) > 12 then label = utf8u.sub(label, 1, 11) .. "…" end
        local marker = w.minimised and "_" or (w.focused and ">" or " ")
        local chip = " " .. marker .. label .. " "
        local chip_w = utf8u.len(chip)
        if x + chip_w > b.x + b.w - right_reserve then break end
        local chip_fg = w.focused and 0xFFFFFF or TB_FG
        local chip_bg = w.focused and acc or 0x2A3340
        paint(x, chip, chip_fg, chip_bg)
        self.chips[#self.chips + 1] = { x1 = x, x2 = x + chip_w - 1, kind = "win", win = w.win }
        x = x + chip_w + 1
      end

      -- Right side: user, clock, power pill (red).
      local user_clock = " " .. (self.props.user or "root") .. "  " .. clock_text() .. " "
      local pwr        = " " .. lang.t("bar.power") .. " "
      local pwr_w      = utf8u.len(pwr)
      local uc_w       = utf8u.len(user_clock)
      local px         = b.x + b.w - pwr_w
      local ucx        = px - uc_w
      paint(ucx, user_clock, TB_FG, TB_BG)
      paint(px,  pwr,        0xFFFFFF, 0xCC4444)
      self.chips[#self.chips + 1] = { x1 = px, x2 = px + pwr_w - 1, kind = "power" }
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
