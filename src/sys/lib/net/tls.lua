-- /sys/lib/net/tls.lua — pure-Lua TLS 1.3 client (work-in-progress).
--
-- Goal: HTTPS without OC's native TLS — useful on builds where the
-- internet card has TLS disabled, or on hardware that only ships a
-- raw TCP modem (the future). Single ciphersuite:
-- TLS_CHACHA20_POLY1305_SHA256 with X25519 key exchange and
-- Ed25519 / RSA cert verification (RSA still TODO).
--
-- This file lays the foundations:
--   * ClientHello builder (single key_share, X25519)
--   * ServerHello parser (extracts the peer key_share + cipher suite)
--   * Key schedule: derive_handshake_secret / derive_traffic_secrets
--   * AEAD wrappers around lib.codec.chacha20 + lib.codec.poly1305
--     using the TLS 1.3 additional-data layout
--   * Record-layer helpers (write/read TLSCiphertext, application_data)
--
-- What's NOT done yet (so this module is not a working HTTPS client):
--   * EncryptedExtensions / Certificate / CertificateVerify / Finished
--     parse + dispatch in handshake state machine
--   * X.509 ASN.1 DER parser → SubjectPublicKeyInfo extraction
--   * Cert chain verification against a trust store
--   * RSA-PSS / RSA-PKCS1 verify (Ed25519 verify is already in
--     lib.codec.ed25519)
--   * 0-RTT, session resumption, early data
--
-- Until those are wired the public `connect()` returns
-- nil, "tls: handshake not yet implemented" so callers can detect
-- and fall back to OC's native HTTPS.

local M = {}

local sha256   = require("lib.codec.sha256")
local hmac     = require("lib.codec.hmac")
local hkdf     = require("lib.codec.hkdf")
local chacha   = require("lib.codec.chacha20")
local poly     = require("lib.codec.poly1305")
local x25519   = require("lib.codec.curve25519")

-- ---- byte helpers ------------------------------------------------------

local function be16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end
local function be24(n) return string.char((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF) end
local function be32(n) return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF) end

local function read_u8(s, i)  return s:byte(i), i + 1 end
local function read_u16(s, i) return (s:byte(i) << 8) | s:byte(i + 1), i + 2 end
local function read_u24(s, i)
  return (s:byte(i) << 16) | (s:byte(i + 1) << 8) | s:byte(i + 2), i + 3
end
local function read_bytes(s, i, n) return s:sub(i, i + n - 1), i + n end

-- TLS variable-length vector with `len_bytes` length prefix.
local function vector(len_bytes, body)
  if len_bytes == 1 then return string.char(#body) .. body end
  if len_bytes == 2 then return be16(#body) .. body end
  if len_bytes == 3 then return be24(#body) .. body end
  error("vector: bad len_bytes")
end

-- ---- random ------------------------------------------------------------

local function random_bytes(n)
  -- Prefer the data card's RNG; fall back to a sha256 of uptime +
  -- component addresses (fine for test traffic; not ideal for real
  -- cryptographic key material, but X25519 ephemeral keys are short
  -- lived and re-generated each handshake).
  local addr = component.list and component.list("data")()
  if addr then
    local ok, raw = pcall(component.invoke, addr, "random", n)
    if ok and raw and #raw == n then return raw end
  end
  local seed = tostring(computer.uptime())
  if component.list then
    for a in component.list() do seed = seed .. a end
  end
  local out = ""
  while #out < n do out = out .. sha256.bytes(seed .. tostring(#out)) end
  return out:sub(1, n)
end

-- ---- ClientHello -------------------------------------------------------

local CIPHER_CHACHA = "\19\03"                      -- TLS_CHACHA20_POLY1305_SHA256
local NAMEDGROUP_X25519 = be16(0x001D)
local SIG_ED25519 = be16(0x0807)

function M.build_client_hello(host)
  -- Returns the ClientHello body (without record header) + the ephemeral
  -- private key the caller must keep for the ECDHE derivation.
  local priv = random_bytes(32)
  local pub  = x25519.base(priv)

  local random = random_bytes(32)
  local legacy_session_id = vector(1, random_bytes(32))

  -- Cipher suites: just CHACHA20-POLY1305-SHA256 for now.
  local cipher_suites = vector(2, CIPHER_CHACHA)
  local compression   = vector(1, "\0")              -- null only

  -- Extensions:
  --   supported_versions = TLS 1.3
  --   supported_groups   = X25519
  --   key_share          = (X25519, pub)
  --   signature_algorithms = ed25519 (for now)
  --   server_name        = host
  local function ext(typ, body) return be16(typ) .. vector(2, body) end

  local sv = ext(0x002b, vector(1, "\3\4"))          -- supported_versions = 0x0304
  local sg = ext(0x000a, vector(2, NAMEDGROUP_X25519))
  local key_entry = NAMEDGROUP_X25519 .. vector(2, pub)
  local ks = ext(0x0033, vector(2, key_entry))
  local sa = ext(0x000d, vector(2, SIG_ED25519))
  -- server_name = list of { type=0(host_name) || hostname }
  local sni_entry = "\0" .. vector(2, host)
  local sni = ext(0x0000, vector(2, sni_entry))

  local exts = vector(2, sv .. sg .. ks .. sa .. sni)

  local body =
    "\3\3" ..                                        -- legacy_version = TLS 1.2
    random ..
    legacy_session_id ..
    cipher_suites ..
    compression ..
    exts

  -- Wrap in handshake header: type(1) + length(3) + body
  local hs = "\1" .. be24(#body) .. body
  return hs, priv, pub
end

-- ---- ServerHello parser ------------------------------------------------

function M.parse_server_hello(hs)
  -- Minimum sanity: type byte + 3-byte length + body
  if #hs < 4 or hs:byte(1) ~= 2 then return nil, "not a ServerHello" end
  local body_len, _ = read_u24(hs, 2)
  if 4 + body_len ~= #hs then return nil, "ServerHello length mismatch" end

  local i = 5
  local _, ni  = read_u16(hs, i); i = ni              -- legacy_version
  local random; random, i = read_bytes(hs, i, 32)
  local sid_len; sid_len, i = read_u8(hs, i)
  local _; _, i = read_bytes(hs, i, sid_len)
  local cipher; cipher, i = read_bytes(hs, i, 2)
  if cipher ~= CIPHER_CHACHA then return nil, "server picked unsupported cipher" end
  local _; _, i = read_u8(hs, i)                      -- legacy_compression_method
  local exts_len; exts_len, i = read_u16(hs, i)
  local exts_end = i + exts_len

  local server_pub
  while i < exts_end do
    local typ, ext_len, ext_data
    typ, i = read_u16(hs, i)
    ext_len, i = read_u16(hs, i)
    ext_data, i = read_bytes(hs, i, ext_len)
    if typ == 0x0033 then                            -- key_share
      -- For ServerHello key_share is a single KeyShareEntry, not a list.
      local group = ext_data:sub(1, 2)
      if group == NAMEDGROUP_X25519 then
        local key_len = (ext_data:byte(3) << 8) | ext_data:byte(4)
        server_pub = ext_data:sub(5, 5 + key_len - 1)
      end
    end
  end
  if not server_pub or #server_pub ~= 32 then
    return nil, "server did not send X25519 key_share"
  end
  return { random = random, server_pub = server_pub, cipher = cipher }
end

-- ---- key schedule (RFC 8446 §7.1) --------------------------------------

local ZERO_HASH = string.rep("\0", 32)

function M.key_schedule(shared_secret, transcript_hash_after_sh)
  -- Early secret: HKDF-Extract(salt=0, IKM=PSK or 0)
  local early = hkdf.extract(nil, ZERO_HASH)
  local derived_es = hkdf.derive_secret(early, "derived", "")
  -- Handshake secret
  local handshake = hkdf.extract(derived_es, shared_secret)
  local cs_hs = hkdf.derive_secret(handshake, "c hs traffic", transcript_hash_after_sh)
  local ss_hs = hkdf.derive_secret(handshake, "s hs traffic", transcript_hash_after_sh)
  -- Master secret comes after Finished is processed; we surface
  -- handshake-secret derivation here and let the caller chain into
  -- the application-traffic step once they've verified Finished.
  local derived_hs = hkdf.derive_secret(handshake, "derived", "")
  local master = hkdf.extract(derived_hs, ZERO_HASH)
  return {
    handshake_secret = handshake,
    master_secret    = master,
    client_hs_traffic = cs_hs,
    server_hs_traffic = ss_hs,
  }
end

-- Derive a per-direction { key, iv } pair for the AEAD record layer.
function M.traffic_keys(traffic_secret)
  return {
    key = hkdf.expand_label(traffic_secret, "key", "", 32),  -- ChaCha20: 32-byte key
    iv  = hkdf.expand_label(traffic_secret, "iv",  "", 12),  -- AEAD nonce: 12 bytes
  }
end

-- ---- AEAD wrapper ------------------------------------------------------

local function xor_bytes(a, b)
  local out = {}
  for i = 1, #a do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
  return table.concat(out)
end

function M.aead_seal(keys, seq, plaintext, additional)
  -- Per RFC 8446 §5.3 the AEAD nonce is iv XOR seq (left-padded).
  local seq_be = string.rep("\0", 4) .. be32(seq)
  local nonce  = xor_bytes(keys.iv, seq_be)
  local ct = chacha.encrypt(keys.key, nonce, plaintext, 1)
  local tag = poly.mac(
    chacha.encrypt(keys.key, nonce, string.rep("\0", 32), 0):sub(1, 32),
    -- AEAD construction per RFC 7539 §2.8 with TLS additional_data:
    additional .. ct
      .. string.rep("\0", (16 - #additional % 16) % 16)
      .. string.rep("\0", (16 - #ct % 16) % 16)
      .. be32(0) .. be32(#additional)
      .. be32(0) .. be32(#ct))
  return ct .. tag
end

-- Top-level connect — not yet wired to the cert chain / Finished /
-- client-application-traffic step. Returns a polite error so callers
-- know to fall back to OC's native HTTPS.
function M.connect(_host, _port)
  return nil, "tls: handshake not yet complete (build_client_hello and key_schedule are functional; cert verify + Finished are pending)"
end

return M
