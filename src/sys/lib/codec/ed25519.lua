-- /sys/lib/codec/ed25519.lua — Ed25519 sign / verify (RFC 8032).
--
-- Pure Lua 5.3 port. The field arithmetic comes from
-- /sys/lib/codec/curve25519.lua's exposed `_fe` table — same 16-limb
-- 2^16-radix representation TweetNaCl uses. Only the Edwards-curve
-- point operations and the reduction mod the group order L live here.
--
-- Public API:
--   ed25519.public_key(secret_32B)          -> 32-byte public key
--   ed25519.sign(secret_32B, message)       -> 64-byte signature
--   ed25519.verify(public_32B, message, sig) -> boolean
--
-- Performance: a sign or verify costs ~512 field-multiplications via
-- the ladder + ~50 SHA-512 blocks. On a T3 OC machine that is roughly
-- 1.5 seconds. Callers must yield via sched.sleep(0) somewhere on the
-- stack so the kernel watchdog doesn't trip during long operations.

local M = {}

local fe     = require("lib.codec.curve25519")._fe
local sha512 = require("lib.codec.sha512")

local fe_zero, fe_one, fe_copy = fe.zero, fe.one, fe.copy
local fe_add, fe_sub, fe_mul, fe_sq = fe.add, fe.sub, fe.mul, fe.sq
local fe_invert, fe_to_bytes, fe_from_bytes = fe.invert, fe.to_bytes, fe.from_bytes

-- ---- curve constants ---------------------------------------------------

-- d   = -121665 / 121666 mod p (Edwards curve constant)
-- d2  = 2 * d
local D  = { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
             0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 }
local D2 = { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
             0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 }
-- I  = sqrt(-1) mod p, used to decompress points.
local I  = { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
             0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 }

-- Group order L = 2^252 + 27742317777372353535851937790883648493.
-- Stored low-byte first to match RFC 8032.
local L = {
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
  0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
}

-- ---- helpers -----------------------------------------------------------

local function bytes_to_byte_array(s)
  local out = {}
  for i = 1, #s do out[i] = s:byte(i) end
  return out
end

local function byte_array_to_string(arr, n)
  n = n or #arr
  local out = {}
  for i = 1, n do out[i] = string.char(arr[i] & 0xFF) end
  return table.concat(out)
end

-- ---- Edwards point operations (extended coords {X, Y, Z, T}) -----------

local function pt_zero()
  return { fe_zero(), fe_one(), fe_one(), fe_zero() }
end

-- TweetNaCl `add` on extended coords: P = P + Q.
local function pt_add(P, Q)
  local A, B, C, D_, E, F, G, H = fe_zero(), fe_zero(), fe_zero(), fe_zero(),
                                  fe_zero(), fe_zero(), fe_zero(), fe_zero()
  fe_sub(A, P[2], P[1]);   fe_sub(B, Q[2], Q[1]);   fe_mul(A, A, B)
  fe_add(B, P[1], P[2]);   fe_add(C, Q[1], Q[2]);   fe_mul(B, B, C)
  fe_mul(C, P[4], Q[4]);   fe_mul(C, C, D2)
  fe_mul(D_, P[3], Q[3]);  fe_add(D_, D_, D_)
  fe_sub(E, B, A); fe_sub(F, D_, C); fe_add(G, D_, C); fe_add(H, B, A)
  fe_mul(P[1], E, F)
  fe_mul(P[2], H, G)
  fe_mul(P[3], G, F)
  fe_mul(P[4], E, H)
end

-- Conditional move: if b==1, copy Q into P.
local function pt_cmov(P, Q, b)
  fe.cswap(P[1], Q[1], b); fe.cswap(P[2], Q[2], b)
  fe.cswap(P[3], Q[3], b); fe.cswap(P[4], Q[4], b)
  -- TweetNaCl uses cswap then re-swaps; net effect of one cswap is
  -- swap-when-b=1. After cswap: if b==1 then P holds old Q and Q holds
  -- old P. We want P = Q (no swap of caller's Q value preferable, but
  -- the caller passes in fresh tables so swapping is fine).
end

-- Copy Q into P (no-op for Q).
local function pt_copy(P, Q)
  for i = 1, 4 do for j = 1, 16 do P[i][j] = Q[i][j] end end
end

-- TweetNaCl scalarmult on Edwards: P = a * Q where a is a 32-byte
-- little-endian scalar.
local function pt_scalarmult(P, Q, a)
  -- Initialise P to identity (0:1:1:0).
  for i = 1, 16 do
    P[1][i] = 0; P[2][i] = 0; P[3][i] = 0; P[4][i] = 0
  end
  P[2][1] = 1; P[3][1] = 1
  for i = 255, 0, -1 do
    local b = (a[(i >> 3) + 1] >> (i & 7)) & 1
    pt_cmov(P, Q, b)
    pt_add(Q, P)            -- Q = Q + P (this is the "saved" double trick)
    pt_add(P, P)            -- P = 2P
    pt_cmov(P, Q, b)
  end
end

-- The Ed25519 base point as extended coords. y = 4/5, x derived; both
-- precomputed and packed via fe_from_bytes for clarity.
local BASE_X = fe_from_bytes(string.char(
  0x1A, 0xD5, 0x25, 0x8F, 0x60, 0x2D, 0x56, 0xC9,
  0xB2, 0xA7, 0x25, 0x95, 0x60, 0xC7, 0x2C, 0x69,
  0x5C, 0xDC, 0xD6, 0xFD, 0x31, 0xE2, 0xA4, 0xC0,
  0xFE, 0x53, 0x6E, 0xCD, 0xD3, 0x36, 0x69, 0x21))
local BASE_Y = fe_from_bytes(string.char(
  0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
  0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
  0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
  0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66))
-- Wipe the high bit of BASE_X — it isn't part of the encoding.
-- BASE_Y high bit is the parity flag; mask is already done by fe_from_bytes.

local function base_point()
  local P = { fe_copy(BASE_X), fe_copy(BASE_Y), fe_one(), fe_zero() }
  fe_mul(P[4], BASE_X, BASE_Y)                      -- T = X*Y
  return P
end

-- ---- point encoding / decoding -----------------------------------------

-- pack point: y || (sign of x in the high bit)
local function pt_pack(P)
  local zi, tx, ty = fe_zero(), fe_zero(), fe_zero()
  fe_invert(zi, P[3])
  fe_mul(tx, P[1], zi)
  fe_mul(ty, P[2], zi)
  local out = fe_to_bytes(ty)
  -- The low bit of x becomes the sign flag in byte 31 bit 7.
  local x_bytes = fe_to_bytes(tx)
  local low_x = x_bytes:byte(1) & 1
  local b = { out:byte(1, 32) }
  b[32] = b[32] ~ (low_x << 7)
  local s = {}
  for i = 1, 32 do s[i] = string.char(b[i]) end
  return table.concat(s)
end

-- Decode 32-byte y to a curve point. Returns the NEGATED point
-- (TweetNaCl convention used by the verify routine). Returns nil on
-- decoding failure (point not on curve).
local function pt_unpack_neg(s)
  local y = fe_from_bytes(s)                        -- y, ignoring high bit
  -- (sign bit lives in bit 7 of byte 31 of the original s)
  local sign = (s:byte(32) >> 7) & 1

  -- Solve x^2 = (y^2 - 1) / (d*y^2 + 1)
  local num, den, den2, den4, den6, t, x, ck = fe_zero(), fe_zero(), fe_zero(),
                                                fe_zero(), fe_zero(), fe_zero(),
                                                fe_zero(), fe_zero()
  fe_sq(num, y); fe_sub(num, num, fe_one())
  fe_sq(den, y); fe_mul(den, den, D); fe_add(den, den, fe_one())

  fe_sq(den2, den); fe_sq(den4, den2); fe_mul(den6, den4, den2)
  fe_mul(t, den6, num); fe_mul(t, t, den)
  -- t = num * den^7 ; raise to (p-5)/8 = 2^252 - 3 via square-and-multiply
  local function pow2523(out, a)
    local c = fe_copy(a)
    for i = 250, 0, -1 do
      fe_sq(c, c); if i ~= 1 then fe_mul(c, c, a) end
    end
    for j = 1, 16 do out[j] = c[j] end
  end
  pow2523(t, t)
  -- x = num * den^3 * (num*den^7)^((p-5)/8)
  fe_mul(t, t, num); fe_mul(t, t, den); fe_mul(t, t, den)
  fe_mul(x, t, den)

  -- Check x^2 * den == num. If not, multiply x by sqrt(-1).
  fe_sq(ck, x); fe_mul(ck, ck, den)
  fe_sub(ck, ck, num)
  -- if ck != 0, try x = x * I
  -- We approximate "is zero" by repeated carry then comparing to canonical 0.
  fe.carry(ck); fe.carry(ck); fe.carry(ck)
  local nonzero = false
  do
    local b = fe_to_bytes(fe_copy(ck))
    for i = 1, 32 do if b:byte(i) ~= 0 then nonzero = true; break end end
  end
  if nonzero then
    fe_mul(x, x, I)
    fe_sq(ck, x); fe_mul(ck, ck, den)
    fe_sub(ck, ck, num)
    fe.carry(ck); fe.carry(ck); fe.carry(ck)
    local b = fe_to_bytes(fe_copy(ck))
    for i = 1, 32 do
      if b:byte(i) ~= 0 then return nil end          -- not on curve
    end
  end

  -- Match the requested sign of x.
  local xb = fe_to_bytes(fe_copy(x))
  if (xb:byte(1) & 1) ~= sign then
    -- negate x: x = p - x. Implement as: zero - x then carry.
    local zero = fe_zero()
    local nx = fe_zero(); fe_sub(nx, zero, x)
    for j = 1, 16 do x[j] = nx[j] end
  end

  -- Negated point (-x, y, 1, -x*y) for verify: TweetNaCl flips x.
  local P = { fe_zero(), fe_copy(y), fe_one(), fe_zero() }
  do
    local zero = fe_zero(); fe_sub(P[1], zero, x)
  end
  fe_mul(P[4], P[1], y)
  return P
end

-- ---- modular reduction mod L ------------------------------------------

-- Reduce a 64-byte little-endian integer in `x` modulo L, in-place,
-- writing the resulting 32-byte residue back to x[1..32]. Direct port
-- of TweetNaCl's modL — Lua 5.3's `>>` is logical, so we use floor
-- division to get the arithmetic-shift semantics the algorithm needs
-- when limbs swing negative (same bug pattern as in curve25519's
-- carry chain).
local function ashr(x, k) return (x - (x % (1 << k))) // (1 << k) end

local function modL(x)
  for i = 64, 33, -1 do
    local carry = 0
    local lo, hi = i - 32, i - 13
    local k = 1
    for j = lo, hi do
      x[j] = x[j] + carry - 16 * x[i] * L[k]
      carry = ashr(x[j] + 128, 8)
      x[j] = x[j] - (carry * 256)
      k = k + 1
    end
    x[i - 12] = x[i - 12] + carry
    x[i] = 0
  end
  local carry = 0
  for j = 1, 32 do
    x[j] = x[j] + carry - ashr(x[32], 4) * L[j]
    carry = ashr(x[j], 8)
    x[j] = x[j] - carry * 256
  end
  for j = 1, 32 do x[j] = x[j] - carry * L[j] end
  for i = 1, 32 do
    x[i + 1] = (x[i + 1] or 0) + ashr(x[i], 8)
    x[i] = x[i] & 0xFF
  end
end

local function reduce_64(buf)
  -- buf is 64-byte string; treat as 64 i64 values (will be made 32 bytes).
  local x = {}
  for i = 1, 64 do x[i] = buf:byte(i) end
  for i = 65, 128 do x[i] = 0 end
  modL(x)
  return byte_array_to_string(x, 32)
end

-- ---- public API --------------------------------------------------------

local function clamp_secret(h32)
  local b = bytes_to_byte_array(h32)
  b[1] = b[1] & 248
  b[32] = (b[32] & 127) | 64
  return b                                          -- byte array, 32 entries
end

function M.public_key(secret)
  assert(#secret == 32, "ed25519 secret must be 32 bytes")
  local h = sha512.bytes(secret)                    -- 64 bytes
  local a = clamp_secret(h:sub(1, 32))
  local A = pt_zero()
  pt_scalarmult(A, base_point(), a)
  return pt_pack(A)
end

function M.sign(secret, msg)
  assert(#secret == 32, "ed25519 secret must be 32 bytes")
  local h = sha512.bytes(secret)
  local a_arr = clamp_secret(h:sub(1, 32))
  local prefix = h:sub(33, 64)
  local A_pt = pt_zero(); pt_scalarmult(A_pt, base_point(), a_arr)
  local A_enc = pt_pack(A_pt)

  local r_str = reduce_64(sha512.bytes(prefix .. msg))
  local r_arr = bytes_to_byte_array(r_str)
  local R_pt  = pt_zero(); pt_scalarmult(R_pt, base_point(), r_arr)
  local R_enc = pt_pack(R_pt)

  local k_str = reduce_64(sha512.bytes(R_enc .. A_enc .. msg))
  local k_arr = bytes_to_byte_array(k_str)

  -- s = r + k * a (mod L)
  local x = {}
  for i = 1, 64 do x[i] = 0 end
  for i = 1, 32 do x[i] = r_arr[i] end
  for i = 1, 32 do
    for j = 1, 32 do
      x[i + j - 1] = x[i + j - 1] + k_arr[i] * a_arr[j]
    end
  end
  modL(x)
  return R_enc .. byte_array_to_string(x, 32)
end

function M.verify(pub, msg, sig)
  if #pub ~= 32 or #sig ~= 64 then return false end
  if (sig:byte(64) & 224) ~= 0 then return false end -- s out of range
  local A_neg = pt_unpack_neg(pub)
  if not A_neg then return false end

  local R_enc = sig:sub(1, 32)
  local s_enc = sig:sub(33, 64)

  local k_str = reduce_64(sha512.bytes(R_enc .. pub .. msg))
  local k_arr = bytes_to_byte_array(k_str)
  local s_arr = bytes_to_byte_array(s_enc)

  -- p = s*B + k*(-A)
  local p1 = pt_zero(); pt_scalarmult(p1, base_point(), s_arr)
  local p2 = pt_zero(); pt_scalarmult(p2, A_neg,        k_arr)
  pt_add(p1, p2)
  -- Compare against R.
  local p_enc = pt_pack(p1)
  if p_enc ~= R_enc then return false end
  return true
end

return M
