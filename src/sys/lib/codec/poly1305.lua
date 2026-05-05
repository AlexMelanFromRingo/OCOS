-- /sys/lib/codec/poly1305.lua — pure-Lua Poly1305 (RFC 7539 §2.5).
--
-- Poly1305 is a one-time MAC. The output authenticates a message under
-- a 32-byte key. It is paired with ChaCha20 for AEAD (chacha20-poly1305)
-- in TLS, WireGuard, and the OCOS package signature path when no T3
-- Data Card is available.
--
-- Public API:
--   poly1305.mac(key, msg) -> 16-byte tag
--
-- Implementation notes: the prime field is 2^130-5 and the multiplications
-- are 130-bit, so we operate on 5-limb (26-bit per limb) representations
-- with 64-bit Lua integers (which Lua 5.3 native ints are). Limbs fit in
-- 30 bits with carry slack; intermediate products fit in 56 bits. No
-- explicit big-int library required.

local M = {}

local MASK26 = 0x3FFFFFF                          -- 2^26 - 1

local function clamp_r(r)
  -- Per RFC 7539 §2.5.1.
  local out = { string.byte(r, 1, 16) }
  out[4]  = out[4]  & 15
  out[8]  = out[8]  & 15
  out[12] = out[12] & 15
  out[16] = out[16] & 15
  out[5]  = out[5]  & 252
  out[9]  = out[9]  & 252
  out[13] = out[13] & 252
  return string.char(table.unpack(out))
end

local function load_limbs(s)
  -- 17-byte little-endian → 5 × 26-bit limbs.
  local b = { string.byte(s, 1, 17) }
  for i = #b + 1, 17 do b[i] = 0 end
  local h = {}
  h[1] = b[1] | (b[2] << 8) | (b[3] << 16) | ((b[4] & 0x03) << 24)
  h[2] = ((b[4] >> 2) & 0x3F) | (b[5] << 6) | (b[6] << 14) | ((b[7] & 0x0F) << 22)
  h[3] = ((b[7] >> 4) & 0x0F) | (b[8] << 4) | (b[9] << 12) | ((b[10] & 0x3F) << 20)
  h[4] = ((b[10] >> 6) & 0x03) | (b[11] << 2) | (b[12] << 10) | (b[13] << 18)
  h[5] = b[14] | (b[15] << 8) | (b[16] << 16) | (b[17] << 24)
  return h
end

local function add_limbs(a, b)
  for i = 1, 5 do a[i] = a[i] + b[i] end
end

local function multiply(h, r)
  -- Schoolbook 5×5 multiply mod 2^130-5. Fold high limbs back via × 5.
  local r0, r1, r2, r3, r4 = r[1], r[2], r[3], r[4], r[5]
  local h0, h1, h2, h3, h4 = h[1], h[2], h[3], h[4], h[5]
  local s1, s2, s3, s4 = r1 * 5, r2 * 5, r3 * 5, r4 * 5
  local d0 = h0*r0 + h1*s4 + h2*s3 + h3*s2 + h4*s1
  local d1 = h0*r1 + h1*r0 + h2*s4 + h3*s3 + h4*s2
  local d2 = h0*r2 + h1*r1 + h2*r0 + h3*s4 + h4*s3
  local d3 = h0*r3 + h1*r2 + h2*r1 + h3*r0 + h4*s4
  local d4 = h0*r4 + h1*r3 + h2*r2 + h3*r1 + h4*r0
  -- Carry-propagate.
  local c
  c = d0 >> 26; h[1] = d0 & MASK26
  d1 = d1 + c
  c = d1 >> 26; h[2] = d1 & MASK26
  d2 = d2 + c
  c = d2 >> 26; h[3] = d2 & MASK26
  d3 = d3 + c
  c = d3 >> 26; h[4] = d3 & MASK26
  d4 = d4 + c
  c = d4 >> 26; h[5] = d4 & MASK26
  h[1] = h[1] + c * 5
  c = h[1] >> 26; h[1] = h[1] & MASK26
  h[2] = h[2] + c
end

local function freeze(h)
  -- Reduce h modulo p exactly once if h ≥ p.
  local g = { h[1] + 5, h[2], h[3], h[4], h[5] }
  local c
  c = g[1] >> 26; g[1] = g[1] & MASK26; g[2] = g[2] + c
  c = g[2] >> 26; g[2] = g[2] & MASK26; g[3] = g[3] + c
  c = g[3] >> 26; g[3] = g[3] & MASK26; g[4] = g[4] + c
  c = g[4] >> 26; g[4] = g[4] & MASK26; g[5] = g[5] + c
  c = g[5] >> 26; g[5] = g[5] & MASK26
  -- Choose g if c ≠ 0 (i.e., overflowed past 2^130).
  if c ~= 0 then for i = 1, 5 do h[i] = g[i] end end
end

function M.mac(key, msg)
  if #key ~= 32 then return nil, "key must be 32 bytes" end
  local r = clamp_r(key:sub(1, 16))
  local s = key:sub(17, 32)
  local r_limbs = load_limbs(r .. "\0")
  local h = { 0, 0, 0, 0, 0 }

  local pos, total = 1, #msg
  while pos <= total do
    local n = math.min(16, total - pos + 1)
    local chunk = msg:sub(pos, pos + n - 1)
    if n < 16 then
      chunk = chunk .. "\1" .. string.rep("\0", 16 - n)
    else
      chunk = chunk .. "\1"
    end
    local m = load_limbs(chunk)
    add_limbs(h, m)
    multiply(h, r_limbs)
    pos = pos + n
  end
  freeze(h)
  -- Pack 5 × 26 → 4 × 32 little-endian + add s.
  local p0 = (h[1]      | (h[2] << 26))         & 0xFFFFFFFF
  local p1 = ((h[2] >> 6) | (h[3] << 20))       & 0xFFFFFFFF
  local p2 = ((h[3] >> 12) | (h[4] << 14))      & 0xFFFFFFFF
  local p3 = ((h[4] >> 18) | (h[5] << 8))       & 0xFFFFFFFF
  local words = { p0, p1, p2, p3 }
  -- Add little-endian s as a 128-bit integer with carry.
  local carry = 0
  local out = {}
  for i = 1, 4 do
    local s_word = string.byte(s, (i-1)*4+1)
                 | (string.byte(s, (i-1)*4+2) << 8)
                 | (string.byte(s, (i-1)*4+3) << 16)
                 | (string.byte(s, (i-1)*4+4) << 24)
    local sum = words[i] + s_word + carry
    carry = (sum >> 32) & 1
    local w = sum & 0xFFFFFFFF
    out[#out + 1] = string.char(w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF)
  end
  return table.concat(out)
end

return M
