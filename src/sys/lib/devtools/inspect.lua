-- /sys/lib/devtools/inspect.lua — pretty-printer for Lua values.
--
-- Cycle-safe: tables are tagged on first visit and printed as `<table:N>`
-- on revisit. Keys are sorted (numbers before strings, then lexicographic).
-- Strings longer than `max_string` are truncated with an ellipsis.

local M = {}

local function default_opts(o)
  o = o or {}
  o.max_depth  = o.max_depth  or 6
  o.max_string = o.max_string or 200
  o.max_keys   = o.max_keys   or 64
  return o
end

local function key_lt(a, b)
  local ta, tb = type(a), type(b)
  if ta == tb then
    if ta == "number" then return a < b end
    return tostring(a) < tostring(b)
  end
  return ta == "number"
end

local function fmt_string(s, opts)
  if #s > opts.max_string then s = s:sub(1, opts.max_string) .. "…" end
  return string.format("%q", s)
end

local function inspect_value(v, opts, depth, seen, out)
  local t = type(v)
  if t == "string" then out[#out + 1] = fmt_string(v, opts); return end
  if t == "number" or t == "boolean" or t == "nil" then out[#out + 1] = tostring(v); return end
  if t == "function" then out[#out + 1] = "<function>"; return end
  if t == "userdata" then out[#out + 1] = "<userdata>"; return end
  if t == "thread" then out[#out + 1] = "<thread>"; return end
  if t ~= "table" then out[#out + 1] = "<" .. t .. ">"; return end

  if seen[v] then out[#out + 1] = "<table:" .. seen[v] .. ">"; return end
  seen.count = (seen.count or 0) + 1
  seen[v] = seen.count
  if depth >= opts.max_depth then out[#out + 1] = "<table:" .. seen[v] .. " ...>"; return end

  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, key_lt)
  if #keys == 0 then out[#out + 1] = "{}"; return end

  out[#out + 1] = "{\n"
  local indent = string.rep("  ", depth + 1)
  local close = string.rep("  ", depth)
  for i, k in ipairs(keys) do
    if i > opts.max_keys then
      out[#out + 1] = indent .. "... (" .. (#keys - opts.max_keys) .. " more)\n"
      break
    end
    out[#out + 1] = indent
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      out[#out + 1] = k
    else
      out[#out + 1] = "[" .. (type(k) == "string" and fmt_string(k, opts) or tostring(k)) .. "]"
    end
    out[#out + 1] = " = "
    inspect_value(v[k], opts, depth + 1, seen, out)
    out[#out + 1] = ",\n"
  end
  out[#out + 1] = close .. "}"
end

function M.inspect(value, opts)
  local out = {}
  inspect_value(value, default_opts(opts), 0, {}, out)
  return table.concat(out)
end

function M.print(value, opts)
  io.write(M.inspect(value, opts), "\n")
end

return M
