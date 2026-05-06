-- /sys/lib/codec/ecdsa.lua — ECDSA verify on the NIST P-256 curve.
--
-- Pure-Lua port using lib/codec/bigint for the field math (so the
-- speed scales with the new Knuth-D divmod). Implements just enough
-- to validate a TLS/X.509 signature — verify, not sign — over the
-- single curve P-256 with SHA-256/384/512 digests. Other NIST
-- curves (P-384, P-521) use the same skeleton but ship different
-- domain parameters; they're left as a future drop-in if any cert
-- chain we hit in the wild needs them.
--
-- Public API:
--   ecdsa.verify(pub, hash_bytes, signature) -> ok, err
--     pub.kind = "ecdsa-p256"
--     pub.x, pub.y = bigints (256-bit each)
--     signature = DER-encoded SEQUENCE { r INTEGER, s INTEGER }

local M = {}

local bi   = require("lib.codec.bigint")
local asn1 = require("lib.codec.asn1")

-- ---- domain parameters -------------------------------------------------

local function from_hex(h) return bi.from_bytes((h:gsub("..", function(c) return string.char(tonumber(c, 16)) end))) end

local P  = from_hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
local A  = from_hex("ffffffff00000001000000000000000000000000fffffffffffffffffffffffc")  -- p - 3
local B  = from_hex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b")
local N  = from_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
local Gx = from_hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
local Gy = from_hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
local ZERO, ONE, TWO, THREE = bi.zero(), bi.one(), { 2 }, { 3 }
local N_MINUS_TWO = bi.sub(N, TWO)

-- ---- field arithmetic mod P -------------------------------------------

local function fp_add(a, b) return bi.mod(bi.add(a, b), P) end
local function fp_sub(a, b)
  if bi.cmp(a, b) >= 0 then return bi.sub(a, b) end
  return bi.sub(bi.add(a, P), b)
end
local function fp_mul(a, b) return bi.mod(bi.mul(a, b), P) end
local function fp_sq(a)     return fp_mul(a, a) end
local function fp_inv(a)    return bi.modexp(a, bi.sub(P, TWO), P) end

-- ---- point ops in Jacobian coords --------------------------------------

local function jac_zero() return { x = ONE, y = ONE, z = ZERO } end
local function jac_is_zero(P_) return bi.is_zero(P_.z) end

local function jac_from_affine(x, y)
  return { x = x, y = y, z = ONE }
end

local function jac_to_affine(P_)
  if jac_is_zero(P_) then return nil, nil end
  local zinv  = fp_inv(P_.z)
  local zinv2 = fp_sq(zinv)
  local zinv3 = fp_mul(zinv2, zinv)
  return fp_mul(P_.x, zinv2), fp_mul(P_.y, zinv3)
end

-- Doubling (a = -3 form): RFC 6090 / SEC 1.
local function jac_double(P_)
  if jac_is_zero(P_) then return jac_zero() end
  -- delta = z^2 ; gamma = y^2
  local delta = fp_sq(P_.z)
  local gamma = fp_sq(P_.y)
  -- alpha = 3 * (x - delta) * (x + delta)   (using a = -3)
  local alpha = fp_mul(THREE, fp_mul(fp_sub(P_.x, delta), fp_add(P_.x, delta)))
  -- beta = x * gamma
  local beta  = fp_mul(P_.x, gamma)
  -- x3 = alpha^2 - 8*beta
  local eight_beta = fp_mul({ 8 }, beta)
  local x3 = fp_sub(fp_sq(alpha), eight_beta)
  -- z3 = (y + z)^2 - gamma - delta
  local z3 = fp_sub(fp_sub(fp_sq(fp_add(P_.y, P_.z)), gamma), delta)
  -- y3 = alpha*(4*beta - x3) - 8*gamma^2
  local four_beta = fp_mul({ 4 }, beta)
  local y3 = fp_sub(fp_mul(alpha, fp_sub(four_beta, x3)),
                    fp_mul({ 8 }, fp_sq(gamma)))
  return { x = x3, y = y3, z = z3 }
end

-- Addition: P (jacobian) + Q (jacobian).
local function jac_add(P_, Q_)
  if jac_is_zero(P_) then return Q_ end
  if jac_is_zero(Q_) then return P_ end
  -- z1z1 = z1^2 ; z2z2 = z2^2
  local z1z1 = fp_sq(P_.z)
  local z2z2 = fp_sq(Q_.z)
  -- u1 = x1*z2z2 ; u2 = x2*z1z1
  local u1 = fp_mul(P_.x, z2z2)
  local u2 = fp_mul(Q_.x, z1z1)
  -- s1 = y1*z2*z2z2 ; s2 = y2*z1*z1z1
  local s1 = fp_mul(P_.y, fp_mul(Q_.z, z2z2))
  local s2 = fp_mul(Q_.y, fp_mul(P_.z, z1z1))
  if bi.cmp(u1, u2) == 0 then
    if bi.cmp(s1, s2) ~= 0 then return jac_zero() end
    return jac_double(P_)
  end
  local h = fp_sub(u2, u1)
  local i = fp_sq(fp_mul(TWO, h))
  local j = fp_mul(h, i)
  local r = fp_mul(TWO, fp_sub(s2, s1))
  local v = fp_mul(u1, i)
  -- x3 = r^2 - j - 2*v
  local x3 = fp_sub(fp_sub(fp_sq(r), j), fp_mul(TWO, v))
  -- y3 = r*(v - x3) - 2*s1*j
  local y3 = fp_sub(fp_mul(r, fp_sub(v, x3)), fp_mul(TWO, fp_mul(s1, j)))
  -- z3 = ((z1 + z2)^2 - z1z1 - z2z2) * h
  local z3 = fp_mul(
    fp_sub(fp_sub(fp_sq(fp_add(P_.z, Q_.z)), z1z1), z2z2),
    h)
  return { x = x3, y = y3, z = z3 }
end

local function bit_at(k, i)
  -- bit i of bigint k (i counted from 0 = LSB).
  local limb_idx = (i // 16) + 1
  local bit_in   = i % 16
  local limb     = k[limb_idx] or 0
  return (limb >> bit_in) & 1
end

local function bit_length(k)
  for i = #k, 1, -1 do
    if k[i] ~= 0 then
      local b = 16
      while b > 0 and ((k[i] >> (b - 1)) & 1) == 0 do b = b - 1 end
      return (i - 1) * 16 + b
    end
  end
  return 0
end

local function jac_scalar_mul(k, P_)
  -- Plain double-and-add MSB→LSB. ~256 doublings + ~128 additions per
  -- scalar mul on P-256, no windowing — verify is two scalarmuls so
  -- ~3-5 s on T1 even after the Knuth-D divmod speedup.
  local R = jac_zero()
  for i = bit_length(k) - 1, 0, -1 do
    R = jac_double(R)
    if bit_at(k, i) == 1 then R = jac_add(R, P_) end
  end
  return R
end

-- ---- ECDSA verify ------------------------------------------------------

local function int_in_range(n, lo, hi)
  return bi.cmp(n, lo) >= 0 and bi.cmp(n, hi) < 0
end

local function parse_sig(der)
  -- DER: SEQUENCE { r INTEGER, s INTEGER }
  local seq = asn1.read(der, 1)
  if seq.tag ~= 0x10 then return nil, "ecdsa: signature not SEQUENCE" end
  local i = 1
  local rn = asn1.read(seq.body, i); i = rn.next_off
  local sn = asn1.read(seq.body, i)
  if rn.tag ~= 0x02 or sn.tag ~= 0x02 then return nil, "ecdsa: r/s not INTEGER" end
  return bi.from_bytes(rn.body), bi.from_bytes(sn.body)
end

function M.verify(pub, hash_bytes, signature)
  if pub.kind ~= "ecdsa-p256" then return false, "ecdsa: not a P-256 key" end
  local r, s = parse_sig(signature)
  if not r then return false, s end
  if not int_in_range(r, ONE, N) then return false, "r out of range" end
  if not int_in_range(s, ONE, N) then return false, "s out of range" end

  -- z = leftmost bytes of hash_bytes mod n. P-256's n is 256 bits, so
  -- SHA-256 hashes of 256 bits map directly. SHA-384/512 hashes get
  -- truncated by taking the leftmost 32 bytes.
  local z_bytes = hash_bytes
  if #z_bytes > 32 then z_bytes = z_bytes:sub(1, 32) end
  local z = bi.mod(bi.from_bytes(z_bytes), N)

  -- w = s^-1 mod n
  local w  = bi.modexp(s, N_MINUS_TWO, N)
  local u1 = bi.mod(bi.mul(z, w), N)
  local u2 = bi.mod(bi.mul(r, w), N)

  -- (X, Y) = u1*G + u2*Q
  local G = jac_from_affine(Gx, Gy)
  local Q = jac_from_affine(pub.x, pub.y)
  local sum = jac_add(jac_scalar_mul(u1, G), jac_scalar_mul(u2, Q))
  if jac_is_zero(sum) then return false, "result is point at infinity" end

  local X, _ = jac_to_affine(sum)
  if not X then return false, "verify: cannot project" end
  return bi.cmp(bi.mod(X, N), r) == 0
end

return M
