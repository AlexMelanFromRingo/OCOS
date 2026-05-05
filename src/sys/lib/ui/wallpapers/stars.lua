-- /sys/lib/ui/wallpapers/stars.lua — sparse starfield pattern.
--
-- Returns a deterministic-but-noisy pattern function suitable for the
-- wallpaper widget's `pattern` prop. The seed is captured per call so the
-- starfield is stable across re-renders.

local function hash(x, y, seed)
  local h = (x * 374761393 + y * 668265263 + seed * 1442695040) & 0xffffffff
  h = h ~ (h >> 13); h = (h * 1274126177) & 0xffffffff
  return h ~ (h >> 16)
end

return function(seed)
  seed = seed or 1
  return function(x, y, theme)
    local h = hash(x, y, seed)
    if (h & 0xff) > 244 then
      return "*", theme.palette.fg, theme.desktop and theme.desktop.bg or theme.palette.bg
    elseif (h & 0xff) > 240 then
      return ".", theme.palette.muted, theme.desktop and theme.desktop.bg or theme.palette.bg
    end
    return " ", theme.palette.fg, theme.desktop and theme.desktop.bg or theme.palette.bg
  end
end
