-- /sys/lib/term/keymap.lua — translates LWJGL key codes into editor actions.
--
-- The console's line editor and the M3 widgets both consume the same
-- action-name dictionary. Keys not listed here fall through to the
-- printable-character path.

local M = {}

local CODE_TO_ACTION = {
  [28]  = "enter",
  [156] = "enter",                                 -- numpad enter
  [14]  = "backspace",
  [211] = "delete",
  [203] = "left",
  [205] = "right",
  [200] = "up",
  [208] = "down",
  [199] = "home",
  [207] = "end",
  [15]  = "tab",
  [1]   = "interrupt",                             -- Esc, treated as cancel
}

local CHAR_TO_ACTION = {
  [1]  = "home",                                   -- Ctrl-A
  [3]  = "interrupt",                              -- Ctrl-C
  [4]  = "eof",                                    -- Ctrl-D
  [5]  = "end",                                    -- Ctrl-E
  [11] = "kill_to_eol",                            -- Ctrl-K
  [12] = "redraw",                                 -- Ctrl-L
  [21] = "clear_line",                             -- Ctrl-U
  [23] = "delete_word_back",                       -- Ctrl-W
}

function M.action(code, char)
  return CODE_TO_ACTION[code] or CHAR_TO_ACTION[char]
end

return M
