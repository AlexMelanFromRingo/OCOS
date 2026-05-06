-- /sys/lib/codec/sha256.lua — SHA-256 with optional data-card acceleration.
--
-- The pure-Lua implementation runs in two cycles per byte on the Lua 5.3
-- VM (~150ms per kilobyte on a tier-3 CPU) which is fast enough for package
-- verification. When a data card is attached we delegate to the native
-- implementation, which does the same job in microseconds.

local M = {}

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local INIT_H = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local band, bor, bxor, bnot, shl, shr =
  function(a, b) return a & b end,
  function(a, b) return a | b end,
  function(a, b) return a ~ b end,
  function(a)    return ~a end,
  function(a, n) return (a << n) & 0xffffffff end,
  function(a, n) return (a >> n) & 0xffffffff end

local function rotr(n, b) return ((n >> b) | shl(n, 32 - b)) & 0xffffffff end

local function pack_be32(n)
  return string.char(
    (n >> 24) & 0xff,
    (n >> 16) & 0xff,
    (n >>  8) & 0xff,
     n        & 0xff)
end

local function compress(H, msg, off)
  local W = {}
  for i = 1, 16 do
    local p = off + (i - 1) * 4
    W[i] =
      shl(msg:byte(p + 1), 24) +
      shl(msg:byte(p + 2), 16) +
      shl(msg:byte(p + 3),  8) +
          msg:byte(p + 4)
  end
  for i = 17, 64 do
    local s0 = bxor(bxor(rotr(W[i - 15], 7),  rotr(W[i - 15], 18)), shr(W[i - 15], 3))
    local s1 = bxor(bxor(rotr(W[i - 2],  17), rotr(W[i - 2],  19)), shr(W[i - 2],  10))
    W[i] = (W[i - 16] + s0 + W[i - 7] + s1) & 0xffffffff
  end

  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
  for i = 1, 64 do
    local S1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g)) & 0xffffffff
    local t1 = (h + S1 + ch + K[i] + W[i]) & 0xffffffff
    local S0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
    local mj = bxor(bxor(band(a, b), band(a, c)), band(b, c)) & 0xffffffff
    local t2 = (S0 + mj) & 0xffffffff
    h = g
    g = f
    f = e
    e = (d + t1) & 0xffffffff
    d = c
    c = b
    b = a
    a = (t1 + t2) & 0xffffffff
  end
  H[1] = (H[1] + a) & 0xffffffff
  H[2] = (H[2] + b) & 0xffffffff
  H[3] = (H[3] + c) & 0xffffffff
  H[4] = (H[4] + d) & 0xffffffff
  H[5] = (H[5] + e) & 0xffffffff
  H[6] = (H[6] + f) & 0xffffffff
  H[7] = (H[7] + g) & 0xffffffff
  H[8] = (H[8] + h) & 0xffffffff
end

local function pure_sha256_bytes(msg)
  -- Pad to 64-byte multiple with the 1-bit + length encoding.
  local bit_len = #msg * 8
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do msg = msg .. "\0" end
  msg = msg ..
    string.char((bit_len >> 56) & 0xff, (bit_len >> 48) & 0xff,
                (bit_len >> 40) & 0xff, (bit_len >> 32) & 0xff,
                (bit_len >> 24) & 0xff, (bit_len >> 16) & 0xff,
                (bit_len >>  8) & 0xff,  bit_len        & 0xff)
  local H = { table.unpack(INIT_H) }
  for i = 1, #msg, 64 do compress(H, msg, i - 1) end
  return pack_be32(H[1]) .. pack_be32(H[2]) .. pack_be32(H[3]) .. pack_be32(H[4]) ..
         pack_be32(H[5]) .. pack_be32(H[6]) .. pack_be32(H[7]) .. pack_be32(H[8])
end

local function find_data_card()
  -- `component` is provided by the OC runtime; in unit-test contexts
  -- (host-side Lua running off the repo) it's nil and we just fall
  -- back to the pure-Lua path below.
  if not _G.component or not _G.component.list then return nil end
  local addr = _G.component.list("data")()
  if addr then return _G.component.proxy(addr) end
end

local function to_hex(b)
  return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.bytes(input)
  local card = find_data_card()
  if card and card.sha256 then
    local ok, res = pcall(card.sha256, input)
    if ok and res then return res end
  end
  return pure_sha256_bytes(input)
end

function M.hex(input)
  return to_hex(M.bytes(input))
end

return M
