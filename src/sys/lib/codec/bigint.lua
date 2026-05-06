-- /sys/lib/codec/bigint.lua — minimal big integers for RSA verify.
--
-- Numbers are stored as arrays of 16-bit unsigned limbs, little-endian
-- (limb[1] = least significant), with the convention that the array
-- has no trailing zero limbs except for the canonical zero `{0}`. The
-- representation is signed-magnitude (no negatives are needed for the
-- RSA verify path so we only implement the non-negative subset).
--
-- Public API:
--   bigint.from_bytes(s)   bigint from big-endian bytes (e.g. an ASN.1 INTEGER)
--   bigint.to_bytes(b, n)  big-endian bytes; left-padded to n bytes
--   bigint.cmp(a, b)       -1 / 0 / 1
--   bigint.add(a, b), sub(a, b), mul(a, b)
--   bigint.shl(a, k), shr(a, k)
--   bigint.divmod(a, b) -> q, r
--   bigint.modexp(b, e, m) -> b^e mod m, with cooperative yields

local M = {}

local LIMB    = 65536                                -- radix 2^16
local LIMB_M1 = 65535
local function trim(a)
  while #a > 1 and a[#a] == 0 do a[#a] = nil end
  return a
end

local function copy(a)
  local out = {}
  for i = 1, #a do out[i] = a[i] end
  return out
end

-- Resolve the scheduler exactly once at module-load time so the inner
-- loops don't pay a require()/global-lookup tax per yield. nil in test
-- contexts where there's no kernel; we fall through to pullSignal.
local SCHED
do
  if _G.require then
    local ok, mod = pcall(_G.require, "k.sched")
    if ok and type(mod) == "table" then SCHED = mod end
  end
end

local function yield_ish()
  if SCHED and SCHED.sleep then pcall(SCHED.sleep, 0); return end
  if _G.computer and _G.computer.pullSignal then pcall(_G.computer.pullSignal, 0) end
end

function M.zero() return { 0 } end
function M.one()  return { 1 } end

function M.from_bytes(s)
  if #s == 0 then return M.zero() end
  -- Strip leading zero (DER INTEGER padding for sign) — caller can
  -- pass either form.
  local i = 1
  while i < #s and s:byte(i) == 0 do i = i + 1 end
  local trimmed = s:sub(i)
  -- Pack 2 bytes per limb starting from the LSB end.
  local out = {}
  local n = #trimmed
  local idx = 1
  for j = n, 1, -2 do
    local lo = trimmed:byte(j)
    local hi = (j > 1) and trimmed:byte(j - 1) or 0
    out[idx] = (hi << 8) | lo
    idx = idx + 1
  end
  return trim(out)
end

function M.to_bytes(a, n)
  -- Render LSB-limb array to big-endian byte string. n optionally
  -- left-pads to a fixed length.
  local rev = {}
  for i = #a, 1, -1 do
    rev[#rev + 1] = string.char((a[i] >> 8) & 0xFF, a[i] & 0xFF)
  end
  local out = table.concat(rev)
  -- Trim leading zero bytes that came from the high limb being < 256.
  while #out > 1 and out:byte(1) == 0 do out = out:sub(2) end
  if n and #out < n then out = string.rep("\0", n - #out) .. out end
  return out
end

function M.cmp(a, b)
  if #a ~= #b then return (#a < #b) and -1 or 1 end
  for i = #a, 1, -1 do
    if a[i] ~= b[i] then return (a[i] < b[i]) and -1 or 1 end
  end
  return 0
end

function M.is_zero(a) return #a == 1 and a[1] == 0 end

function M.add(a, b)
  local out, carry, n = {}, 0, math.max(#a, #b)
  for i = 1, n do
    local s = (a[i] or 0) + (b[i] or 0) + carry
    out[i] = s & LIMB_M1
    carry  = s >> 16
  end
  if carry > 0 then out[n + 1] = carry end
  return trim(out)
end

function M.sub(a, b)
  -- Assumes a >= b. Return a - b.
  local out, borrow = {}, 0
  for i = 1, #a do
    local d = a[i] - (b[i] or 0) - borrow
    if d < 0 then d = d + LIMB; borrow = 1 else borrow = 0 end
    out[i] = d
  end
  return trim(out)
end

function M.shl_limb(a, n)
  -- a << (n * 16): prepend n zero limbs.
  if M.is_zero(a) then return M.zero() end
  local out = {}
  for i = 1, n do out[i] = 0 end
  for i = 1, #a do out[i + n] = a[i] end
  return out
end

function M.mul(a, b)
  if M.is_zero(a) or M.is_zero(b) then return M.zero() end
  local out = {}
  for i = 1, #a + #b do out[i] = 0 end
  for i = 1, #a do
    local carry = 0
    for j = 1, #b do
      local p = out[i + j - 1] + a[i] * b[j] + carry
      out[i + j - 1] = p & LIMB_M1
      carry = p >> 16
    end
    out[i + #b] = out[i + #b] + carry
    if i % 16 == 0 then yield_ish() end
  end
  return trim(out)
end

function M.shl_bit(a, k)
  -- a << k bits, k < 16. Used in long division.
  if k == 0 then return copy(a) end
  local out, carry = {}, 0
  for i = 1, #a do
    local v = (a[i] << k) | carry
    out[i] = v & LIMB_M1
    carry  = v >> 16
  end
  if carry > 0 then out[#out + 1] = carry end
  return out
end

function M.divmod(a, b)
  -- Schoolbook long division: returns (q, r) with a = q*b + r.
  -- Assumes b > 0. Slow but adequate for the RSA verify path because
  -- modexp uses repeated mod-mul where each mod is one divmod.
  if M.is_zero(b) then error("bigint.divmod: division by zero") end
  if M.cmp(a, b) < 0 then return M.zero(), copy(a) end
  -- Convert a to a bit list and shift bits one at a time into r,
  -- subtracting b when r >= b. Standard long division.
  local q = {}
  for i = 1, #a do q[i] = 0 end
  local r = M.zero()
  for i = #a, 1, -1 do
    for bit = 15, 0, -1 do
      r = M.shl_bit(r, 1)
      if (a[i] >> bit) & 1 == 1 then r[1] = (r[1] or 0) | 1 end
      r = trim(r)
      if M.cmp(r, b) >= 0 then
        r = M.sub(r, b)
        q[i] = q[i] | (1 << bit)
      end
    end
    if i % 8 == 0 then yield_ish() end
  end
  return trim(q), r
end

function M.mod(a, m)
  local _, r = M.divmod(a, m)
  return r
end

function M.modmul(a, b, m)
  return M.mod(M.mul(a, b), m)
end

function M.modexp(base, exp, modulus)
  -- Square-and-multiply. exp scanned MSB→LSB in 16-bit chunks.
  if M.is_zero(modulus) then error("bigint.modexp: modulus zero") end
  local result = M.one()
  local b = M.mod(base, modulus)
  for i = #exp, 1, -1 do
    local limb = exp[i]
    for bit = 15, 0, -1 do
      result = M.modmul(result, result, modulus)
      if (limb >> bit) & 1 == 1 then
        result = M.modmul(result, b, modulus)
      end
      yield_ish()
    end
  end
  return result
end

return M
