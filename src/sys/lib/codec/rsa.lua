-- /sys/lib/codec/rsa.lua — RSA signature verification (PKCS#1 v1.5).
--
-- The signed payload for SignatureAlgorithm = sha256WithRSAEncryption
-- is: 0x00 0x01 || PS (FF padding) || 0x00 || DigestInfo || hash
-- where DigestInfo is the ASN.1 of (algorithm OID, NULL) plus the
-- OCTET STRING of the hash. We rebuild the expected encoding and
-- compare it byte-for-byte against (signature ^ e) mod n.
--
-- PSS verification (rsa_pss_rsae_sha256, used by TLS 1.3
-- CertificateVerify) is NOT yet implemented — see verify_pss stub.
--
-- API:
--   rsa.verify_pkcs1_v15(pub, hash_alg, hash, signature) -> ok, err

local M = {}

local bigint = require("lib.codec.bigint")

local DIGEST_INFO = {
  ["sha256"] = string.char(
    0x30, 0x31,
      0x30, 0x0D,
        0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
        0x05, 0x00,
      0x04, 0x20),
  ["sha384"] = string.char(
    0x30, 0x41,
      0x30, 0x0D,
        0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02,
        0x05, 0x00,
      0x04, 0x30),
  ["sha512"] = string.char(
    0x30, 0x51,
      0x30, 0x0D,
        0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03,
        0x05, 0x00,
      0x04, 0x40),
}

function M.verify_pkcs1_v15(pub, hash_alg, hash, signature)
  -- pub = { n = bigint, e = bigint }, hash = raw digest bytes
  local k = #bigint.to_bytes(pub.n)
  if #signature ~= k then return false, "signature length mismatch" end
  local sig_bi = bigint.from_bytes(signature)
  local m_bi   = bigint.modexp(sig_bi, pub.e, pub.n)
  local m_bytes = bigint.to_bytes(m_bi, k)
  local di = DIGEST_INFO[hash_alg]
  if not di then return false, "unsupported hash: " .. tostring(hash_alg) end
  local t = di .. hash
  if #t + 11 > k then return false, "intended encoded message too long" end
  local ps_len = k - #t - 3
  local expected = string.char(0x00, 0x01) .. string.rep(string.char(0xFF), ps_len)
                .. string.char(0x00) .. t
  if m_bytes ~= expected then return false, "PKCS#1 v1.5 padding mismatch" end
  return true
end

-- ---- RSA-PSS verify (RFC 8017 §8.1) -----------------------------------

local sha256 = require("lib.codec.sha256")

local function HASH_FOR(alg)
  if alg == "sha256" then return sha256.bytes, 32 end
  -- Larger hashes can be wired here if/when sha384.lua / sha512.lua
  -- gain a `bytes` helper alongside their `hex` one.
  error("rsa-pss: unsupported hash: " .. tostring(alg))
end

local function xor_bytes(a, b)
  local out = {}
  for i = 1, #a do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
  return table.concat(out)
end

local function be32(n)
  return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

-- MGF1 (RFC 8017 §B.2.1): T = T || Hash(mgfSeed || C) for C = 0, 1, ...
local function mgf1(seed, length, hash_fn, hash_len)
  local out = {}
  local need = math.ceil(length / hash_len)
  for i = 0, need - 1 do
    out[#out + 1] = hash_fn(seed .. be32(i))
  end
  return table.concat(out):sub(1, length)
end

function M.verify_pss(pub, hash_alg, m_hash, signature)
  local hash_fn, h_len = HASH_FOR(hash_alg)
  local k = #bigint.to_bytes(pub.n)                  -- modulus length in bytes
  if #signature ~= k then return false, "signature length mismatch" end
  local sig_bi = bigint.from_bytes(signature)
  if bigint.cmp(sig_bi, pub.n) >= 0 then
    return false, "signature numerically >= modulus"
  end
  local m_bi   = bigint.modexp(sig_bi, pub.e, pub.n)
  local em     = bigint.to_bytes(m_bi, k)

  -- emBits = modulusBitLength - 1; emLen = ceil(emBits / 8). For RSA
  -- with 2048-bit n and a high bit set, emBits = 2047, emLen = 256 = k.
  -- Per RFC 8017 §9.1.2 step 4 the leftmost (8*emLen - emBits) bits of
  -- maskedDB must be zero — for the common 2048/2 case that's 1 bit.
  local em_bits = (#bigint.to_bytes(pub.n) * 8) - 1   -- approximate
  local em_len  = math.ceil(em_bits / 8)
  if #em > em_len then em = em:sub(#em - em_len + 1) end

  local s_len = h_len                                 -- TLS 1.3 RSA-PSS salt length = hash length
  if em_len < h_len + s_len + 2 then
    return false, "encoded message too short for PSS parameters"
  end

  if em:byte(em_len) ~= 0xBC then
    return false, "PSS trailer mismatch"
  end
  local masked_db = em:sub(1, em_len - h_len - 1)
  local h         = em:sub(em_len - h_len, em_len - 1)

  -- High bit of maskedDB must already be zero (RFC 8017 §9.1.2 step 6).
  local left_zero_bits = 8 * em_len - em_bits
  if left_zero_bits > 0 then
    local mask = 0xFF >> left_zero_bits
    if (masked_db:byte(1) & ~mask) ~= 0 then
      return false, "PSS leftmost bits not zero"
    end
  end

  local db_mask = mgf1(h, em_len - h_len - 1, hash_fn, h_len)
  local db = xor_bytes(masked_db, db_mask)
  if left_zero_bits > 0 then
    local mask = 0xFF >> left_zero_bits
    db = string.char(db:byte(1) & mask) .. db:sub(2)
  end

  -- DB layout: PS (zeros) || 0x01 || salt
  local ps_len = em_len - h_len - s_len - 2
  for i = 1, ps_len do
    if db:byte(i) ~= 0x00 then return false, "PSS PS not all zero" end
  end
  if db:byte(ps_len + 1) ~= 0x01 then return false, "PSS missing 0x01 separator" end
  local salt = db:sub(ps_len + 2)
  if #salt ~= s_len then return false, "PSS salt length wrong" end

  -- M' = (8 zero bytes) || mHash || salt;  H' = Hash(M')
  local m_prime = string.rep("\0", 8) .. m_hash .. salt
  local h_prime = hash_fn(m_prime)
  if h_prime ~= h then return false, "PSS hash mismatch" end
  return true
end

return M
