-- /sys/lib/codec/json.lua — strict JSON encoder/decoder.
--
-- Decoder is a hand-written recursive-descent parser; it accepts the JSON
-- grammar exactly (no comments, no trailing commas, strict number form).
-- Encoder produces minified output by default; pretty-printing is available
-- via `encode(t, { pretty = true })`.

local M = {}

local null_marker = {}
M.null = null_marker

-- ---- decoder ------------------------------------------------------------

local function decode_error(state, msg)
  error(("json: %s at byte %d"):format(msg, state.pos), 0)
end

local function skip_ws(state)
  local s, p = state.src, state.pos
  while p <= #s do
    local c = s:byte(p)
    if c == 32 or c == 9 or c == 10 or c == 13 then p = p + 1
    else break end
  end
  state.pos = p
end

local function expect(state, ch)
  if state.src:sub(state.pos, state.pos) ~= ch then
    decode_error(state, "expected '" .. ch .. "'")
  end
  state.pos = state.pos + 1
end

local decode_value

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_string(state)
  expect(state, '"')
  local out, s, p = {}, state.src, state.pos
  while p <= #s do
    local ch = s:sub(p, p)
    if ch == '"' then state.pos = p + 1; return table.concat(out)
    elseif ch == "\\" then
      local nxt = s:sub(p + 1, p + 1)
      if ESCAPES[nxt] then out[#out + 1] = ESCAPES[nxt]; p = p + 2
      elseif nxt == "u" then
        local hex = s:sub(p + 2, p + 5)
        if not hex:match("^%x%x%x%x$") then state.pos = p; decode_error(state, "bad \\u escape") end
        local cp = tonumber(hex, 16)
        if cp < 0x80 then out[#out + 1] = string.char(cp)
        elseif cp < 0x800 then
          out[#out + 1] = string.char(0xc0 + (cp >> 6), 0x80 + (cp & 0x3f))
        else
          out[#out + 1] = string.char(0xe0 + (cp >> 12), 0x80 + ((cp >> 6) & 0x3f), 0x80 + (cp & 0x3f))
        end
        p = p + 6
      else state.pos = p; decode_error(state, "bad escape") end
    else out[#out + 1] = ch; p = p + 1 end
  end
  state.pos = p; decode_error(state, "unterminated string")
end

local function decode_number(state)
  local s, p0 = state.src, state.pos
  local p = p0
  if s:sub(p, p) == "-" then p = p + 1 end
  while p <= #s and s:sub(p, p):match("[%d%.eE+-]") do p = p + 1 end
  local n = tonumber(s:sub(p0, p - 1))
  if not n then state.pos = p0; decode_error(state, "bad number") end
  state.pos = p; return n
end

local function decode_array(state)
  expect(state, "[")
  local arr = {}
  skip_ws(state)
  if state.src:sub(state.pos, state.pos) == "]" then state.pos = state.pos + 1; return arr end
  while true do
    skip_ws(state)
    arr[#arr + 1] = decode_value(state)
    skip_ws(state)
    local ch = state.src:sub(state.pos, state.pos)
    if ch == "," then state.pos = state.pos + 1
    elseif ch == "]" then state.pos = state.pos + 1; return arr
    else decode_error(state, "expected ',' or ']'") end
  end
end

local function decode_object(state)
  expect(state, "{")
  local obj = {}
  skip_ws(state)
  if state.src:sub(state.pos, state.pos) == "}" then state.pos = state.pos + 1; return obj end
  while true do
    skip_ws(state)
    if state.src:sub(state.pos, state.pos) ~= '"' then decode_error(state, "expected key string") end
    local key = decode_string(state)
    skip_ws(state); expect(state, ":"); skip_ws(state)
    obj[key] = decode_value(state)
    skip_ws(state)
    local ch = state.src:sub(state.pos, state.pos)
    if ch == "," then state.pos = state.pos + 1
    elseif ch == "}" then state.pos = state.pos + 1; return obj
    else decode_error(state, "expected ',' or '}'") end
  end
end

decode_value = function(state)
  skip_ws(state)
  local ch = state.src:sub(state.pos, state.pos)
  if ch == "{" then return decode_object(state) end
  if ch == "[" then return decode_array(state) end
  if ch == '"' then return decode_string(state) end
  if ch:match("[%d%-]") then return decode_number(state) end
  if state.src:sub(state.pos, state.pos + 3) == "true"  then state.pos = state.pos + 4; return true end
  if state.src:sub(state.pos, state.pos + 4) == "false" then state.pos = state.pos + 5; return false end
  if state.src:sub(state.pos, state.pos + 3) == "null"  then state.pos = state.pos + 4; return null_marker end
  decode_error(state, "unexpected character '" .. ch .. "'")
end

function M.decode(src)
  local state = { src = src, pos = 1 }
  local ok, result = pcall(decode_value, state)
  if not ok then return nil, result end
  skip_ws(state)
  if state.pos <= #src then return nil, "json: trailing characters at byte " .. state.pos end
  return result
end

-- ---- encoder ------------------------------------------------------------

local STRING_ESCAPES = {
  ['"']  = '\\"',  ['\\'] = "\\\\",
  ["\b"] = "\\b",  ["\f"] = "\\f",
  ["\n"] = "\\n",  ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
  return '"' .. s:gsub('[%c\\"]', function(c)
    return STRING_ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
    n = math.max(n, k)
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

local encode

local function encode_array(t, opts, depth)
  if #t == 0 then return "[]" end
  if not opts.pretty then
    local parts = {}
    for i, v in ipairs(t) do parts[i] = encode(v, opts, depth + 1) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local pad  = string.rep("  ", depth + 1)
  local pad0 = string.rep("  ", depth)
  local parts = {}
  for i, v in ipairs(t) do parts[i] = pad .. encode(v, opts, depth + 1) end
  return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad0 .. "]"
end

local function encode_object(t, opts, depth)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then return "{}" end
  if not opts.pretty then
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = encode_string(tostring(k)) .. ":" .. encode(t[k], opts, depth + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local pad  = string.rep("  ", depth + 1)
  local pad0 = string.rep("  ", depth)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = pad .. encode_string(tostring(k)) .. ": " .. encode(t[k], opts, depth + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad0 .. "}"
end

encode = function(value, opts, depth)
  depth = depth or 0
  if value == null_marker  then return "null" end
  if value == nil          then return "null" end
  local t = type(value)
  if t == "string"  then return encode_string(value) end
  if t == "number"  then
    if value ~= value then error("json: NaN is not encodable", 0) end
    if value == math.huge or value == -math.huge then error("json: Inf is not encodable", 0) end
    if math.type(value) == "integer" then return tostring(value) end
    return string.format("%.14g", value)
  end
  if t == "boolean" then return tostring(value) end
  if t == "table" then
    if is_array(value) then return encode_array(value, opts, depth) end
    return encode_object(value, opts, depth)
  end
  error("json: cannot encode " .. t, 0)
end

function M.encode(value, opts) return encode(value, opts or {}, 0) end

return M
