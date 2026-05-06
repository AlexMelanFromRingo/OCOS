-- /sys/lib/codec/curve25519.lua — X25519 key agreement (RFC 7748).
--
-- Pure Lua 5.3 port. Field elements are 16-limb arrays of signed
-- 16-bit numbers (radix 2^16) — the same representation TweetNaCl
-- uses, chosen because every limb-pair multiplication fits in 32 bits
-- and an accumulator over 16 such products still fits comfortably in
-- 64-bit Lua integers.
--
-- Passes the RFC 7748 §5.2 reference vectors (vector 1 and iterated
-- k_1 = X25519(9, 9)). Note Lua 5.3's `>>` is logical (zero-fill);
-- the carry chain uses ashr16 below to get the arithmetic-shift
-- behaviour TweetNaCl's i64 limbs assume.
--
-- Public API:
--   curve25519.scalarmult(scalar_bytes, u_bytes) -> 32-byte shared secret
--   curve25519.base(scalar_bytes)                -> 32-byte public key
--   curve25519.clamp_scalar(bytes)               -> clamped scalar
--
-- Performance: a single scalarmult costs 255 ladder iterations × ~16
-- field multiplies. On a T3 OC machine this takes a noticeable fraction
-- of a second; callers should yield (sched.sleep(0)) on the calling
-- stack so the kernel watchdog doesn't trip.

local M = {}

local function fe_zero()
  return { 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0 }
end

local function fe_one()
  local h = fe_zero(); h[1] = 1; return h
end

local function fe_copy(a)
  return { a[1],a[2],a[3],a[4], a[5],a[6],a[7],a[8],
           a[9],a[10],a[11],a[12], a[13],a[14],a[15],a[16] }
end

local function fe_from_bytes(s)
  -- 32 little-endian bytes -> 16 little-endian 16-bit limbs.
  local h = {}
  for i = 0, 15 do
    h[i + 1] = s:byte(2*i + 1) | (s:byte(2*i + 2) << 8)
  end
  -- RFC 7748 §5 masks the top bit of u-coordinates.
  h[16] = h[16] & 0x7FFF
  return h
end

-- Arithmetic right shift by 16. Lua 5.3's `>>` is logical (zero-fill),
-- so negative limb values explode into huge positives — TweetNaCl's
-- C code relies on arithmetic shift to sign-extend. math.floor / 2^16
-- gives the same answer as the C `>>` for both positive and negative
-- inputs without depending on the platform's >> semantics.
local function ashr16(x) return (x - (x % 65536)) // 65536 end

local function fe_carry(h)
  -- TweetNaCl car25519 (sv): for each limb add 2^16 then subtract its
  -- new bit-16+ contents shifted back into the next limb. The "-1"
  -- compensates the +2^16 we just added to each limb so non-overflowing
  -- inputs stay unchanged. The final limb folds back via *38 since
  -- 2^256 ≡ 38 (mod p) for p = 2^255 - 19.
  for i = 1, 16 do
    h[i] = h[i] + 65536
    local c = ashr16(h[i])
    if i < 16 then
      h[i + 1] = h[i + 1] + c - 1
    else
      h[1] = h[1] + 38 * (c - 1)
    end
    h[i] = h[i] - (c * 65536)
  end
end

local function fe_to_bytes(h)
  -- Final reduction: the carry pass above leaves h in [0, 2^256-38);
  -- we now need to pick the canonical residue mod p (= 2^255 - 19).
  fe_carry(h)
  fe_carry(h)
  fe_carry(h)
  for _ = 1, 2 do
    local m = {}
    m[1] = h[1] - 0xFFED
    for i = 2, 15 do
      m[i] = h[i] - 0xFFFF - (ashr16(m[i - 1]) & 1)
      m[i - 1] = m[i - 1] & 0xFFFF
    end
    m[16] = h[16] - 0x7FFF - (ashr16(m[15]) & 1)
    local b = ashr16(m[16]) & 1
    m[15] = m[15] & 0xFFFF
    -- if b == 0 (no underflow), m is the smaller residue: copy it back.
    local mask = (1 - b)                              -- 1 if we keep m, 0 if we keep h
    for i = 1, 16 do
      h[i] = h[i] ~ ((h[i] ~ m[i]) & -mask)
    end
  end
  local out = {}
  for i = 0, 15 do
    out[#out + 1] = string.char(h[i + 1] & 0xFF)
    out[#out + 1] = string.char((h[i + 1] >> 8) & 0xFF)
  end
  return table.concat(out)
end

local function fe_add(out, a, b)
  for i = 1, 16 do out[i] = a[i] + b[i] end
end

local function fe_sub(out, a, b)
  for i = 1, 16 do out[i] = a[i] - b[i] end
end

local function fe_mul(out, a, b)
  -- Schoolbook 16x16 with the wrap-around-via-*38 trick.
  local t = {}
  for i = 1, 31 do t[i] = 0 end
  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do
      t[i + j - 1] = t[i + j - 1] + ai * b[j]
    end
  end
  for i = 1, 15 do
    t[i] = t[i] + 38 * t[i + 16]
  end
  for i = 1, 16 do out[i] = t[i] end
  fe_carry(out)
  fe_carry(out)
end

local function fe_sq(out, a) fe_mul(out, a, a) end

local function fe_cswap(a, b, swap)
  -- Branch-free conditional swap. swap is 0 or 1.
  local mask = -swap
  for i = 1, 16 do
    local x = (a[i] ~ b[i]) & mask
    a[i] = a[i] ~ x
    b[i] = b[i] ~ x
  end
end

local function fe_invert(out, z)
  -- z^(p-2) via the standard 254-square / 11-multiply chain.
  local c = fe_copy(z)
  for i = 253, 0, -1 do
    fe_sq(c, c)
    if i ~= 2 and i ~= 4 then fe_mul(c, c, z) end
  end
  for i = 1, 16 do out[i] = c[i] end
end

function M.clamp_scalar(s)
  assert(#s == 32, "X25519 scalar must be 32 bytes")
  local b = { s:byte(1, 32) }
  b[1]  = b[1]  & 248
  b[32] = (b[32] & 127) | 64
  local out = {}
  for i = 1, 32 do out[i] = string.char(b[i]) end
  return table.concat(out)
end

function M.scalarmult(scalar, u_bytes)
  -- Direct port of djb / TweetNaCl crypto_scalarmult: a, b, c, d are
  -- the ladder registers; the conditional swap happens at the top AND
  -- bottom of each iteration with the same bit, which is equivalent to
  -- the "track XOR of consecutive bits" form in RFC 7748 §5.
  assert(#scalar == 32 and #u_bytes == 32, "X25519 inputs must be 32 bytes")
  scalar = M.clamp_scalar(scalar)
  local x = fe_from_bytes(u_bytes)
  local a, c, d = fe_one(), fe_zero(), fe_one()
  local b = fe_copy(x)
  local e, f = fe_zero(), fe_zero()
  local k121665 = fe_zero(); k121665[1] = 121665

  for i = 254, 0, -1 do
    local r = (scalar:byte((i >> 3) + 1) >> (i & 7)) & 1
    fe_cswap(a, b, r)
    fe_cswap(c, d, r)
    fe_add(e, a, c)
    fe_sub(a, a, c)
    fe_add(c, b, d)
    fe_sub(b, b, d)
    fe_sq(d, e)
    fe_sq(f, a)
    fe_mul(a, c, a)
    fe_mul(c, b, e)
    fe_add(e, a, c)
    fe_sub(a, a, c)
    fe_sq(b, a)
    fe_sub(c, d, f)
    fe_mul(a, c, k121665)
    fe_add(a, a, d)
    fe_mul(c, c, a)
    fe_mul(a, d, f)
    fe_mul(d, b, x)
    fe_sq(b, e)
    fe_cswap(a, b, r)
    fe_cswap(c, d, r)
  end

  fe_invert(c, c)
  fe_mul(a, a, c)
  return fe_to_bytes(a)
end

function M.base(scalar)
  -- Base point u = 9 (RFC 7748 §6.1).
  return M.scalarmult(scalar,
    "\009\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000" ..
    "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000")
end

-- Expose the field primitives so ed25519.lua can reuse them without
-- duplicating ~80 lines of carry / multiply code. The contract is:
-- 16-limb signed-int arrays at radix 2^16, semantics matching
-- TweetNaCl. Public callers should still go through M.scalarmult /
-- M.base — these are internal helpers.
M._fe = {
  zero       = fe_zero,
  one        = fe_one,
  copy       = fe_copy,
  add        = fe_add,
  sub        = fe_sub,
  mul        = fe_mul,
  sq         = fe_sq,
  carry      = fe_carry,
  cswap      = fe_cswap,
  invert     = fe_invert,
  from_bytes = fe_from_bytes,
  to_bytes   = fe_to_bytes,
  ashr16     = ashr16,
}

return M
