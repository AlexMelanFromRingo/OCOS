-- /sys/lib/codec/utf8.lua — small UTF-8 helpers.
--
-- The compositor's Buffer:set treats each `ch` as one cell, but most
-- widgets used to iterate strings byte-by-byte (#s, s:sub(i,i)) which
-- splits multi-byte glyphs across cells and produces the corrupted
-- "Пит Пит®н®" you see when the label has cyrillic. Routing every
-- string-painter through this module keeps the rendering coherent.
--
-- Public API:
--   utf8.each(s)     -> iterator yielding one glyph per step
--   utf8.chars(s)    -> array of glyphs
--   utf8.len(s)      -> glyph count
--   utf8.sub(s, a, b)-> substring by glyph index (1-based, inclusive)

local M = {}

function M.each(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local b = s:byte(i)
    local len
    if     b < 0x80 then len = 1
    elseif b < 0xC0 then len = 1                    -- stray continuation
    elseif b < 0xE0 then len = 2
    elseif b < 0xF0 then len = 3
    else                len = 4
    end
    if i + len - 1 > n then len = n - i + 1 end
    local g = s:sub(i, i + len - 1)
    i = i + len
    return g
  end
end

function M.chars(s)
  local out = {}
  for g in M.each(s) do out[#out + 1] = g end
  return out
end

function M.len(s)
  local n = 0
  for _ in M.each(s) do n = n + 1 end
  return n
end

function M.sub(s, a, b)
  local out, i = {}, 0
  for g in M.each(s) do
    i = i + 1
    if i >= a and (not b or i <= b) then out[#out + 1] = g end
    if b and i > b then break end
  end
  return table.concat(out)
end

return M
