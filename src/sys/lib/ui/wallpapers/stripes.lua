-- /sys/lib/ui/wallpapers/stripes.lua — diagonal pinstripe pattern.
--
-- Two-tone diagonal weave. The slash glyph is drawn in the theme's
-- accent_dim colour so the pattern reads on dark backgrounds without
-- competing with widgets for attention.
return function(period)
  period = period or 6
  return function(x, y, theme)
    local bg = (theme.desktop and theme.desktop.bg) or theme.palette.bg
    local accent = theme.palette.accent_dim or theme.palette.surface_alt or bg
    if ((x + y) % period) == 0 then
      return "/", accent, bg
    end
    return " ", theme.palette.fg, bg
  end
end
