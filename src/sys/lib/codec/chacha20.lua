-- /sys/lib/codec/chacha20.lua — pure-Lua ChaCha20 stream cipher (RFC 7539).
--
-- ChaCha20 is a stream cipher that XORs the plaintext with a keystream
-- generated from (key, nonce, counter). It is its own inverse: encrypt
-- and decrypt are the same operation. The OC Data Card does not provide
-- ChaCha20 directly — only AES — so this is the fallback for machines
-- that need a streaming, key-stretched cipher without a tier-2 card.
--
-- Public API:
--   chacha20.encrypt(key, nonce, plaintext, counter?) -> ciphertext
--   chacha20.decrypt(key, nonce, ciphertext, counter?) -> plaintext   -- alias
--
-- Inputs:
--   key      32-byte string (256-bit)
--   nonce    12-byte string (96-bit)
--   counter  defaults to 1 per RFC 7539 §2.4

local M = {}

local band, bxor, lshift, rshift = bit32 and bit32.band or function(a, b) return a & b end,
                                   bit32 and bit32.bxor or function(a, b) return a ~ b end,
                                   bit32 and bit32.lshift or function(a, b) return a << b end,
                                   bit32 and bit32.rshift or function(a, b) return a >> b end

-- We rely on Lua 5.3 native bitwise + integer arithmetic. The above shims
-- exist so this file would still load on a Lua 5.2 build (where `<<` is
-- a syntax error) — they are unused in practice on the OC Lua 5.3 CPU.

local MASK32 = 0xFFFFFFFF
local function add32(a, b) return (a + b) & MASK32 end
local function rotl32(v, n) return ((v << n) | (v >> (32 - n))) & MASK32 end

local function le32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  return (b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)) & MASK32
end

local function le32_to_str(v)
  return string.char(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end

local function quarterround(s, a, b, c, d)
  s[a] = add32(s[a], s[b]); s[d] = rotl32(bxor(s[d], s[a]), 16)
  s[c] = add32(s[c], s[d]); s[b] = rotl32(bxor(s[b], s[c]), 12)
  s[a] = add32(s[a], s[b]); s[d] = rotl32(bxor(s[d], s[a]),  8)
  s[c] = add32(s[c], s[d]); s[b] = rotl32(bxor(s[b], s[c]),  7)
end

local function block(key_words, counter, nonce_words)
  -- The state is 16 little-endian u32 words; layout per RFC 7539 §2.3:
  --   constants(4) | key(8) | counter(1) | nonce(3)
  local s = {
    0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
    key_words[1], key_words[2], key_words[3], key_words[4],
    key_words[5], key_words[6], key_words[7], key_words[8],
    counter & MASK32,
    nonce_words[1], nonce_words[2], nonce_words[3],
  }
  local w = { table.unpack(s) }
  for _ = 1, 10 do
    quarterround(w,  1,  5,  9, 13)
    quarterround(w,  2,  6, 10, 14)
    quarterround(w,  3,  7, 11, 15)
    quarterround(w,  4,  8, 12, 16)
    quarterround(w,  1,  6, 11, 16)
    quarterround(w,  2,  7, 12, 13)
    quarterround(w,  3,  8,  9, 14)
    quarterround(w,  4,  5, 10, 15)
  end
  for i = 1, 16 do w[i] = add32(w[i], s[i]) end
  return w
end

local function check(key, nonce)
  if #key ~= 32 then return "key must be 32 bytes" end
  if #nonce ~= 12 then return "nonce must be 12 bytes" end
end

function M.encrypt(key, nonce, plaintext, counter)
  local err = check(key, nonce); if err then return nil, err end
  counter = counter or 1
  local key_words = {}
  for i = 1, 8 do key_words[i] = le32(key, (i - 1) * 4 + 1) end
  local nonce_words = {}
  for i = 1, 3 do nonce_words[i] = le32(nonce, (i - 1) * 4 + 1) end

  local out = {}
  local total = #plaintext
  local off = 1
  while off <= total do
    local words = block(key_words, counter, nonce_words)
    counter = counter + 1
    local key_stream = {}
    for i = 1, 16 do key_stream[i] = le32_to_str(words[i]) end
    local ks = table.concat(key_stream)
    local n  = math.min(64, total - off + 1)
    local chunk = plaintext:sub(off, off + n - 1)
    local xored = {}
    for i = 1, n do
      xored[i] = string.char(bxor(chunk:byte(i), ks:byte(i)))
    end
    out[#out + 1] = table.concat(xored)
    off = off + n
  end
  return table.concat(out)
end

M.decrypt = M.encrypt
return M
