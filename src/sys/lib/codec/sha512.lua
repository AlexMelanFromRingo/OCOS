-- /sys/lib/codec/sha512.lua — pure-Lua SHA-512 (FIPS 180-4).
--
-- Lua 5.3 integers are 64-bit native, so we can implement the 64-bit
-- word operations directly without limb tricks. This file is the bare
-- minimum needed for Ed25519, which uses SHA-512 internally; we expose
-- the same hex / bytes interface as lib/codec/sha256.lua.

local M = {}

local K = {
  0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
  0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
  0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
  0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
  0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
  0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
  0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
  0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
  0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
  0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
  0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
  0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
  0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
  0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
  0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
  0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
  0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
  0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
  0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
  0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
}

local function rotr64(v, n) return ((v >> n) | (v << (64 - n))) & 0xFFFFFFFFFFFFFFFF end

local function compress(state, block)
  local w = {}
  for t = 1, 16 do
    local i = (t - 1) * 8 + 1
    local b1, b2, b3, b4, b5, b6, b7, b8 = block:byte(i, i + 7)
    w[t] = (b1 << 56) | (b2 << 48) | (b3 << 40) | (b4 << 32) |
           (b5 << 24) | (b6 << 16) | (b7 << 8)  | b8
  end
  for t = 17, 80 do
    local s0 = rotr64(w[t-15], 1) ~ rotr64(w[t-15], 8) ~ (w[t-15] >> 7)
    local s1 = rotr64(w[t-2], 19) ~ rotr64(w[t-2], 61) ~ (w[t-2] >> 6)
    w[t] = (w[t-16] + s0 + w[t-7] + s1) & 0xFFFFFFFFFFFFFFFF
  end
  local a, b, c, d, e, f, g, h = state[1], state[2], state[3], state[4],
                                  state[5], state[6], state[7], state[8]
  for t = 1, 80 do
    local S1 = rotr64(e, 14) ~ rotr64(e, 18) ~ rotr64(e, 41)
    local ch = (e & f) ~ ((~e) & g)
    local temp1 = (h + S1 + ch + K[t] + w[t]) & 0xFFFFFFFFFFFFFFFF
    local S0 = rotr64(a, 28) ~ rotr64(a, 34) ~ rotr64(a, 39)
    local maj = (a & b) ~ (a & c) ~ (b & c)
    local temp2 = (S0 + maj) & 0xFFFFFFFFFFFFFFFF
    h = g; g = f; f = e
    e = (d + temp1) & 0xFFFFFFFFFFFFFFFF
    d = c; c = b; b = a
    a = (temp1 + temp2) & 0xFFFFFFFFFFFFFFFF
  end
  state[1] = (state[1] + a) & 0xFFFFFFFFFFFFFFFF
  state[2] = (state[2] + b) & 0xFFFFFFFFFFFFFFFF
  state[3] = (state[3] + c) & 0xFFFFFFFFFFFFFFFF
  state[4] = (state[4] + d) & 0xFFFFFFFFFFFFFFFF
  state[5] = (state[5] + e) & 0xFFFFFFFFFFFFFFFF
  state[6] = (state[6] + f) & 0xFFFFFFFFFFFFFFFF
  state[7] = (state[7] + g) & 0xFFFFFFFFFFFFFFFF
  state[8] = (state[8] + h) & 0xFFFFFFFFFFFFFFFF
end

local INITIAL = {
  0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
  0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
}

function M.bytes(msg)
  local state = { table.unpack(INITIAL) }
  local len = #msg
  -- SHA-512 pads to 128-byte blocks with the 16-byte length appended;
  -- our messages will not exceed 2^61 bits, so the upper 8 bytes are zero.
  local pad_len = (112 - ((len + 1) % 128)) % 128
  local bitlen_lo = (len * 8) & 0xFFFFFFFFFFFFFFFF
  local padded = msg .. "\x80" .. string.rep("\0", pad_len) ..
    string.rep("\0", 8) ..
    string.char(
      (bitlen_lo >> 56) & 0xFF, (bitlen_lo >> 48) & 0xFF,
      (bitlen_lo >> 40) & 0xFF, (bitlen_lo >> 32) & 0xFF,
      (bitlen_lo >> 24) & 0xFF, (bitlen_lo >> 16) & 0xFF,
      (bitlen_lo >>  8) & 0xFF,  bitlen_lo        & 0xFF)
  for i = 1, #padded, 128 do
    compress(state, padded:sub(i, i + 127))
  end
  local out = {}
  for i = 1, 8 do
    local v = state[i]
    out[#out + 1] = string.char(
      (v >> 56) & 0xFF, (v >> 48) & 0xFF, (v >> 40) & 0xFF, (v >> 32) & 0xFF,
      (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >>  8) & 0xFF,  v        & 0xFF)
  end
  return table.concat(out)
end

function M.hex(msg)
  return (M.bytes(msg):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

return M
