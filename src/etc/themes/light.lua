return {
  inherit = "default",
  palette = {
    bg = 0xF6F6F6, fg = 0x202020,
    surface = 0xFFFFFF, surface_alt = 0xEEEEEE,
    border = 0xCCCCCC, muted = 0x808080,
  },
  desktop  = { bg = 0xE8E8EC },
  taskbar  = { bg = 0xFFFFFF, fg = 0x202020 },
  window   = { bg = 0xFFFFFF, fg = 0x202020, title_bg = 0x4F8AF0, title_fg = 0xFFFFFF, border = 0xCCCCCC },
  label    = { fg = 0x202020 },
  button   = { bg = 0x4F8AF0, fg = 0xFFFFFF, hover_bg = 0x77ACFF, pressed_bg = 0x2F6AC0,
               disabled_bg = 0xDDDDDD, disabled_fg = 0xAAAAAA },
  input    = { bg = 0xFFFFFF, fg = 0x202020, placeholder = 0xAAAAAA,
               focused_bg = 0xFFFFFF, focused_fg = 0x000000, cursor = 0x4F8AF0 },
  list     = { bg = 0xFFFFFF, fg = 0x202020, selected_bg = 0x4F8AF0, selected_fg = 0xFFFFFF },
  menu     = { bg = 0xFFFFFF, fg = 0x202020, hover_bg = 0x4F8AF0, hover_fg = 0xFFFFFF },
}
