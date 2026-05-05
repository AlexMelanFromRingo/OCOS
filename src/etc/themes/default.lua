return {
  palette = {
    bg          = 0x1F1F1F,
    fg          = 0xE6E6E6,
    accent      = 0x4F8AF0,
    accent_dim  = 0x2A4980,
    surface     = 0x2A2A2A,
    surface_alt = 0x333333,
    border      = 0x4A4A4A,
    error       = 0xE05050,
    warn        = 0xE0A040,
    ok          = 0x6CCB6C,
    muted       = 0x808080,
  },

  desktop  = { bg = 0x101010 },
  taskbar  = { bg = 0x252525, fg = 0xCCCCCC, accent = 0x4F8AF0, height = 1 },

  window   = {
    bg        = 0x1F1F1F,
    fg        = 0xE6E6E6,
    title_bg  = 0x4F8AF0,
    title_fg  = 0xFFFFFF,
    border    = 0x2A2A2A,
  },

  label    = { fg = 0xE6E6E6 },
  button   = {
    bg = 0x4F8AF0, fg = 0xFFFFFF,
    hover_bg  = 0x6BA0FF, hover_fg = 0xFFFFFF,
    pressed_bg = 0x2F6AC0, pressed_fg = 0xFFFFFF,
    disabled_bg = 0x404040, disabled_fg = 0x808080,
    padding = { 0, 1, 0, 1 },                     -- top right bottom left
  },
  input    = {
    bg = 0x2A2A2A, fg = 0xE6E6E6,
    placeholder = 0x808080,
    focused_bg = 0x333333, focused_fg = 0xFFFFFF,
    cursor = 0x4F8AF0,
  },
  list     = { bg = 0x1F1F1F, fg = 0xCCCCCC, selected_bg = 0x4F8AF0, selected_fg = 0xFFFFFF },
  checkbox = { fg = 0xE6E6E6, accent = 0x4F8AF0 },
  scrollbar = { track = 0x2A2A2A, thumb = 0x4F8AF0 },
  menu     = { bg = 0x252525, fg = 0xE6E6E6, hover_bg = 0x4F8AF0, hover_fg = 0xFFFFFF },
}
