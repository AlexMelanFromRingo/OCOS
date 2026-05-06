-- /sys/lib/codec/hkdf.lua — HKDF-SHA256 (RFC 5869) and the TLS 1.3
-- HKDF-Expand-Label / Derive-Secret helpers from RFC 8446 §7.1.
--
-- HKDF-Extract(salt, IKM)            -> PRK
-- HKDF-Expand(PRK, info, L)          -> OKM (L ≤ 255 * HashLen)
-- HKDF-Expand-Label(secret, label,
--                   context, length) -> OKM
-- Derive-Secret(secret, label, msgs) -> secret of HashLen bytes
--
-- Built on top of /sys/lib/codec/hmac so the same HMAC-SHA256
-- implementation drives both PBKDF2 and the TLS key schedule.

local M = {}

local hmac = require("lib.codec.hmac")

local HASH_LEN = 32                                 -- SHA-256 output

function M.extract(salt, ikm)
  -- RFC 5869 §2.2: PRK = HMAC-Hash(salt, IKM). When salt is nil/empty
  -- we substitute a 32-byte zero salt as the spec requires.
  if not salt or salt == "" then salt = string.rep("\0", HASH_LEN) end
  return hmac.sha256(salt, ikm)
end

function M.expand(prk, info, length)
  -- RFC 5869 §2.3. T(0) = empty; T(i) = HMAC(PRK, T(i-1) || info || i).
  info = info or ""
  if length > 255 * HASH_LEN then error("hkdf.expand: length too long", 2) end
  local out = {}
  local t = ""
  local i = 1
  while #table.concat(out) < length do
    t = hmac.sha256(prk, t .. info .. string.char(i))
    out[#out + 1] = t
    i = i + 1
  end
  return table.concat(out):sub(1, length)
end

local function be16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end
local function u8(s)   return string.char(#s) end

function M.expand_label(secret, label, context, length)
  -- RFC 8446 §7.1: HkdfLabel = struct {
  --   uint16 length;
  --   opaque label<7..255> = "tls13 " || label;
  --   opaque context<0..255> = context;
  -- }
  context = context or ""
  local full_label = "tls13 " .. label
  local hkdf_label = be16(length) .. u8(full_label) .. full_label .. u8(context) .. context
  return M.expand(secret, hkdf_label, length)
end

function M.derive_secret(secret, label, msgs)
  -- Derive-Secret(secret, label, messages) =
  --   HKDF-Expand-Label(secret, label, Hash(messages), HashLen)
  msgs = msgs or ""
  local sha = require("lib.codec.sha256")
  local context = sha.bytes(msgs)
  return M.expand_label(secret, label, context, HASH_LEN)
end

return M
