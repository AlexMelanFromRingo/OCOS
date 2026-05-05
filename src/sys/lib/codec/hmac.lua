-- /sys/lib/codec/hmac.lua — HMAC-SHA256 over the codec/sha256 primitive.

local M = {}

local sha = require("lib.codec.sha256")

local BLOCK = 64

local function xor_pad(key, b)
  -- Lua 5.3 has bitwise ops on integers; bytewise XOR via string.byte.
  local out = {}
  for i = 1, #key do out[#out + 1] = string.char(key:byte(i) ~ b) end
  for i = #key + 1, BLOCK do out[#out + 1] = string.char(b) end
  return table.concat(out)
end

function M.sha256(key, msg)
  if #key > BLOCK then key = sha.bytes(key) end
  local opad = xor_pad(key, 0x5c)
  local ipad = xor_pad(key, 0x36)
  return sha.bytes(opad .. sha.bytes(ipad .. msg))
end

return M
