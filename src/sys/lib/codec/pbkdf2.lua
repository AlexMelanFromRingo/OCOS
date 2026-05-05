-- /sys/lib/codec/pbkdf2.lua — PBKDF2-HMAC-SHA256 (RFC 2898).
--
-- Output length is fixed at 32 bytes so the call signature is
-- pbkdf2.derive(password, salt, iterations) -> hex string.
--
-- Iteration counts are picked at user-creation time so they stay reasonable
-- on the originating CPU tier. Verification is constant-time.

local M = {}

local hmac = require("lib.codec.hmac")

local function int_be32(n)
  return string.char((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
end

local function xor_str(a, b)
  local out = {}
  for i = 1, #a do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
  return table.concat(out)
end

function M.derive_bytes(password, salt, iters)
  -- We only need 32 bytes of output (one block of HMAC-SHA256).
  local U = hmac.sha256(password, salt .. int_be32(1))
  local T = U
  for _ = 2, iters do
    U = hmac.sha256(password, U)
    T = xor_str(T, U)
  end
  return T
end

local function to_hex(b)
  return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.derive(password, salt, iters)
  return to_hex(M.derive_bytes(password, salt, iters))
end

function M.verify(password, salt, iters, expected_hex)
  local got = M.derive(password, salt, iters)
  if #got ~= #expected_hex then return false end
  -- Constant-time comparison.
  local diff = 0
  for i = 1, #got do diff = diff | (got:byte(i) ~ expected_hex:byte(i)) end
  return diff == 0
end

return M
