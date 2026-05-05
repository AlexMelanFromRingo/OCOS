-- /sys/lib/ui/wallpapers/stripes.lua — diagonal pinstripe pattern.
return function(period, accent_alpha)
  period = period or 4
  return function(x, y, theme)
    local bg = theme.desktop and theme.desktop.bg or theme.palette.bg
    if ((x + y) % period) == 0 then
      return " ", theme.palette.fg, theme.palette.surface_alt or bg
    end
    return " ", theme.palette.fg, bg
  end
end
