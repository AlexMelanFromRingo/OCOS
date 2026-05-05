-- /sys/lib/ui/event.lua — input event factories.
--
-- The compositor translates raw IPC payloads (kbd.key, oc.signal.touch, …)
-- into structured events. Every event has a `type` and a stable shape so
-- widgets can pattern-match without remembering positional argument layouts.

local M = {}

function M.touch(x, y, btn, player) return { type = "touch", x = x, y = y, btn = btn, player = player } end
function M.drag (x, y, btn, player) return { type = "drag",  x = x, y = y, btn = btn, player = player } end
function M.drop (x, y, btn, player) return { type = "drop",  x = x, y = y, btn = btn, player = player } end
function M.scroll(x, y, dir, player) return { type = "scroll", x = x, y = y, dir = dir, player = player } end
function M.key(down, char, code, mods, player)
  return { type = "key", down = down, char = char, code = code, mods = mods or {}, player = player }
end
function M.paste(text, player) return { type = "paste", text = text, player = player } end
function M.resize(w, h)        return { type = "resize", w = w, h = h } end
function M.focus_in()          return { type = "focus_in" } end
function M.focus_out()         return { type = "focus_out" } end

return M
