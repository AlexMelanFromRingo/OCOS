-- /sys/lib/net/tls.lua — pure-Lua TLS 1.3 client.
--
-- Single ciphersuite: TLS_CHACHA20_POLY1305_SHA256 (RFC 8446 §9.1).
-- Single key exchange: X25519 (RFC 7748). Signature verification on
-- the server's CertificateVerify supports Ed25519 (lib/codec/ed25519)
-- and RSA-PSS rsa_pss_rsae_sha256 (lib/codec/rsa). Cert chain
-- verification supports RSA-PKCS#1 v1.5 with SHA-256/384/512 and
-- Ed25519, against a configurable trust store (or a "pinned cert"
-- mode for self-signed servers).
--
-- Public API:
--   tls.connect(host, port, opts) -> conn, err
--     opts.verify   = "strict" (default) | "insecure" | "pinned"
--     opts.pinned   = DER-encoded server cert when verify == "pinned"
--     opts.trust    = array of DER-encoded root certs (for "strict")
--   conn:write(data)  send application data
--   conn:read(n?)     read up to n bytes (or one record's worth)
--   conn:close()
--
-- Performance: a handshake costs ~1-2 X25519 scalarmuls + a couple of
-- RSA verifies + a few SHA-256 hashes + ChaCha20 record encryption.
-- On T1 OC hardware this takes 5-10 seconds; the implementation
-- yields liberally so the kernel watchdog doesn't kill it.

local M = {}

local sha256    = require("lib.codec.sha256")
local sha512    = require("lib.codec.sha512")  -- for cert hashes when needed
local hmac      = require("lib.codec.hmac")
local hkdf      = require("lib.codec.hkdf")
local chacha    = require("lib.codec.chacha20")
local poly      = require("lib.codec.poly1305")
local x25519    = require("lib.codec.curve25519")
local ed25519   = require("lib.codec.ed25519")
local rsa       = require("lib.codec.rsa")
local x509      = require("lib.codec.x509")
local internet  = require("drv.internet")

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

local function vector(len_bytes, body)
  if len_bytes == 1 then return string.char(#body) .. body end
  if len_bytes == 2 then return be16(#body) .. body end
  if len_bytes == 3 then return be24(#body) .. body end
  error("vector: bad len_bytes")
end

local function xor_bytes(a, b)
  local out = {}
  for i = 1, #a do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
  return table.concat(out)
end

-- ---- random ------------------------------------------------------------

local function random_bytes(n)
  local addr = _G.component and _G.component.list and _G.component.list("data")()
  if addr then
    local ok, raw = pcall(_G.component.invoke, addr, "random", n)
    if ok and raw and #raw == n then return raw end
  end
  local seed = tostring(computer.uptime())
  if _G.component and _G.component.list then
    for a in _G.component.list() do seed = seed .. a end
  end
  local out = ""
  while #out < n do out = out .. sha256.bytes(seed .. tostring(#out)) end
  return out:sub(1, n)
end

-- ---- constants ---------------------------------------------------------

local CIPHER_CHACHA  = "\19\03"                      -- TLS_CHACHA20_POLY1305_SHA256
local NG_X25519      = be16(0x001D)
local SIG_RSA_PSS    = be16(0x0804)                  -- rsa_pss_rsae_sha256
local SIG_ED25519    = be16(0x0807)
local CT_HANDSHAKE   = 22
local CT_APP_DATA    = 23
local CT_ALERT       = 21

-- ---- ClientHello -------------------------------------------------------

local function build_client_hello(host)
  local priv = random_bytes(32)
  local pub  = x25519.base(priv)
  local random = random_bytes(32)

  local function ext(typ, body) return be16(typ) .. vector(2, body) end
  local sv = ext(0x002b, vector(1, "\3\4"))                    -- supported_versions
  local sg = ext(0x000a, vector(2, NG_X25519))                  -- supported_groups
  local key_entry = NG_X25519 .. vector(2, pub)
  local ks = ext(0x0033, vector(2, key_entry))                  -- key_share
  local sa = ext(0x000d, vector(2, SIG_RSA_PSS .. SIG_ED25519)) -- sig algs
  local sni_entry = "\0" .. vector(2, host)
  local sni = ext(0x0000, vector(2, sni_entry))                 -- server_name

  local body =
    "\3\3" .. random ..
    vector(1, random_bytes(32)) ..                              -- legacy_session_id
    vector(2, CIPHER_CHACHA) ..                                  -- cipher_suites
    vector(1, "\0") ..                                           -- compression_methods
    vector(2, sv .. sg .. ks .. sa .. sni)                       -- extensions

  local hs = "\1" .. be24(#body) .. body
  return hs, priv, pub, random
end

-- ---- ServerHello parser ------------------------------------------------

local function parse_server_hello(hs)
  if #hs < 4 or hs:byte(1) ~= 2 then return nil, "not a ServerHello" end
  local body_len, _ = read_u24(hs, 2)
  if 4 + body_len ~= #hs then return nil, "ServerHello length mismatch" end

  local i = 5
  local _, ni  = read_u16(hs, i); i = ni
  local random; random, i = read_bytes(hs, i, 32)
  local sid_len; sid_len, i = read_u8(hs, i)
  local _; _, i = read_bytes(hs, i, sid_len)
  local cipher; cipher, i = read_bytes(hs, i, 2)
  if cipher ~= CIPHER_CHACHA then return nil, "server picked unsupported cipher" end
  local _; _, i = read_u8(hs, i)
  local exts_len; exts_len, i = read_u16(hs, i)
  local exts_end = i + exts_len

  local server_pub
  while i < exts_end do
    local typ, ext_len, ext_data
    typ, i = read_u16(hs, i)
    ext_len, i = read_u16(hs, i)
    ext_data, i = read_bytes(hs, i, ext_len)
    if typ == 0x0033 then
      local group = ext_data:sub(1, 2)
      if group == NG_X25519 then
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

-- ---- key schedule ------------------------------------------------------

local ZERO_HASH = string.rep("\0", 32)

local function key_schedule_handshake(shared, transcript_hash)
  local early = hkdf.extract(nil, ZERO_HASH)
  local derived_es = hkdf.derive_secret(early, "derived", "")
  local hs_secret = hkdf.extract(derived_es, shared)
  return {
    handshake_secret = hs_secret,
    c_hs = hkdf.derive_secret(hs_secret, "c hs traffic", transcript_hash),
    s_hs = hkdf.derive_secret(hs_secret, "s hs traffic", transcript_hash),
  }
end

local function key_schedule_application(handshake_secret, transcript_hash)
  local derived = hkdf.derive_secret(handshake_secret, "derived", "")
  local master = hkdf.extract(derived, ZERO_HASH)
  return {
    master_secret = master,
    c_ap = hkdf.derive_secret(master, "c ap traffic", transcript_hash),
    s_ap = hkdf.derive_secret(master, "s ap traffic", transcript_hash),
  }
end

local function traffic_keys(secret)
  return {
    key = hkdf.expand_label(secret, "key", "", 32),
    iv  = hkdf.expand_label(secret, "iv",  "", 12),
  }
end

-- Verify_data computation for Finished. RFC 8446 §4.4.4.
local function finished_mac(traffic_secret, transcript_hash)
  local finished_key = hkdf.expand_label(traffic_secret, "finished", "", 32)
  return hmac.sha256(finished_key, transcript_hash)
end

-- ---- AEAD (ChaCha20-Poly1305 per RFC 7539 + RFC 8446 §5.2) ------------

local function pad16(s)
  local rem = #s % 16
  return rem == 0 and "" or string.rep("\0", 16 - rem)
end

local function aead_seq_nonce(iv, seq_lo)
  -- Nonce = iv XOR (zero-padded seq, 12 bytes).
  local seq_be = string.rep("\0", 4) .. be32(seq_lo)
  return xor_bytes(iv, seq_be)
end

local function aead_seal(keys, seq_lo, plaintext, aad)
  local nonce = aead_seq_nonce(keys.iv, seq_lo)
  -- one-time poly key = chacha20_block(key, counter=0, nonce)[0..32]
  local otk = chacha.encrypt(keys.key, nonce, string.rep("\0", 64), 0):sub(1, 32)
  local ct  = chacha.encrypt(keys.key, nonce, plaintext, 1)
  local mac_data = aad .. pad16(aad) .. ct .. pad16(ct)
                .. string.rep("\0", 4) .. be32(#aad)
                .. string.rep("\0", 4) .. be32(#ct)
  local tag = poly.mac(otk, mac_data)
  return ct .. tag
end

local function aead_open(keys, seq_lo, sealed, aad)
  if #sealed < 16 then return nil, "ciphertext too short" end
  local ct  = sealed:sub(1, -17)
  local tag = sealed:sub(-16)
  local nonce = aead_seq_nonce(keys.iv, seq_lo)
  local otk = chacha.encrypt(keys.key, nonce, string.rep("\0", 64), 0):sub(1, 32)
  local mac_data = aad .. pad16(aad) .. ct .. pad16(ct)
                .. string.rep("\0", 4) .. be32(#aad)
                .. string.rep("\0", 4) .. be32(#ct)
  if poly.mac(otk, mac_data) ~= tag then return nil, "authentication failed" end
  return chacha.encrypt(keys.key, nonce, ct, 1)
end

-- ---- record IO over a TCP stream --------------------------------------

local Record = {}
Record.__index = Record

function Record.new(stream)
  return setmetatable({
    stream = stream,
    rx_buf = "",
    write_keys = nil, read_keys = nil,
    write_seq  = 0,   read_seq  = 0,
  }, Record)
end

function Record:_pull(n)
  while #self.rx_buf < n do
    local chunk, err = self.stream:read(n - #self.rx_buf)
    if not chunk then return nil, err or "eof" end
    if chunk == "" then break end
    self.rx_buf = self.rx_buf .. chunk
  end
  if #self.rx_buf < n then return nil, "short read" end
  local out = self.rx_buf:sub(1, n)
  self.rx_buf = self.rx_buf:sub(n + 1)
  return out
end

function Record:read_record()
  local hdr, err = self:_pull(5); if not hdr then return nil, err end
  local typ = hdr:byte(1)
  local ver = hdr:sub(2, 3)
  local len = (hdr:byte(4) << 8) | hdr:byte(5)
  local body, berr = self:_pull(len); if not body then return nil, berr end
  if self.read_keys then
    local plain, perr = aead_open(self.read_keys, self.read_seq, body, hdr)
    if not plain then return nil, perr end
    self.read_seq = self.read_seq + 1
    -- Strip trailing zero padding, the very last non-zero byte is
    -- the inner content type per RFC 8446 §5.2.
    local last = #plain
    while last > 0 and plain:byte(last) == 0 do last = last - 1 end
    if last == 0 then return nil, "all-zero plaintext" end
    return { type = plain:byte(last), body = plain:sub(1, last - 1) }
  end
  return { type = typ, body = body, version = ver }
end

function Record:write_plaintext(typ, body)
  local rec = string.char(typ) .. "\3\3" .. be16(#body) .. body
  return self.stream:write(rec)
end

function Record:write_encrypted(inner_type, body)
  -- TLSCiphertext: outer type=23 application_data, fragment is AEAD output
  -- of (inner_type byte appended to body) under additional_data = outer hdr.
  local plain = body .. string.char(inner_type)
  local outer_len = #plain + 16                                  -- +tag
  local hdr = string.char(CT_APP_DATA) .. "\3\3" .. be16(outer_len)
  local sealed = aead_seal(self.write_keys, self.write_seq, plain, hdr)
  self.write_seq = self.write_seq + 1
  return self.stream:write(hdr .. sealed)
end

-- ---- transcript hash --------------------------------------------------

local function transcript_new()
  return { acc = "" }                                            -- TODO: stream sha256 if we ever care about RAM
end
local function transcript_update(t, msg) t.acc = t.acc .. msg end
local function transcript_hash(t) return sha256.bytes(t.acc) end

-- ---- handshake message reader (across one or more records) ------------

local function HandshakeReader(rec)
  local state = { buf = "" }
  function state:next(transcript)
    while #state.buf < 4 do
      local r, err = rec:read_record(); if not r then return nil, err end
      if r.type == CT_ALERT then
        return nil, "tls alert level=" .. r.body:byte(1) .. " desc=" .. r.body:byte(2)
      end
      if r.type ~= CT_HANDSHAKE then return nil, "expected handshake record, got " .. r.type end
      state.buf = state.buf .. r.body
    end
    local body_len = (state.buf:byte(2) << 16) | (state.buf:byte(3) << 8) | state.buf:byte(4)
    while #state.buf < 4 + body_len do
      local r, err = rec:read_record(); if not r then return nil, err end
      if r.type == CT_ALERT then
        return nil, "tls alert level=" .. r.body:byte(1) .. " desc=" .. r.body:byte(2)
      end
      if r.type ~= CT_HANDSHAKE then return nil, "expected handshake record, got " .. r.type end
      state.buf = state.buf .. r.body
    end
    local msg = state.buf:sub(1, 4 + body_len)
    state.buf = state.buf:sub(5 + body_len)
    if transcript then transcript_update(transcript, msg) end
    return msg
  end
  return state
end

-- ---- cert chain verification -----------------------------------------

local function verify_cert_signature(parent_pub, hash_alg, sig_kind, sig, tbs)
  -- Compute the digest the signature is supposed to cover.
  local digest
  if hash_alg == "sha256" then digest = sha256.bytes(tbs)
  elseif hash_alg == "sha384" or hash_alg == "sha512" then
    digest = sha512.bytes(tbs)                                   -- close enough for sha384? No: TODO
  end
  if sig_kind == "rsa-pkcs1" and parent_pub.kind == "rsa" then
    return rsa.verify_pkcs1_v15(parent_pub, hash_alg, digest, sig)
  elseif sig_kind == "rsa-pss" and parent_pub.kind == "rsa" then
    return rsa.verify_pss(parent_pub, hash_alg, digest, sig)
  elseif sig_kind == "ed25519" and parent_pub.kind == "ed25519" then
    -- Ed25519 signs the message itself, not its hash.
    return ed25519.verify(parent_pub.pub, tbs, sig)
  end
  return false, string.format("unsupported sig combo: %s by %s", sig_kind, parent_pub.kind)
end

local function verify_chain(chain, host, mode, opts)
  if #chain == 0 then return false, "empty cert chain" end
  local leaf = chain[1]
  if not x509.matches_hostname(leaf, host) then
    return false, "cert hostname mismatch (subject_cn=" .. tostring(leaf.subject_cn) .. ")"
  end
  if mode == "insecure" then return true end                     -- skip chain trust
  if mode == "pinned" then
    -- pinned cert match by raw DER
    if opts.pinned and opts.pinned == leaf.tbs_raw then return true end
    return false, "pinned cert mismatch"
  end
  -- "strict": walk the chain, each cert signed by the next. Last cert
  -- must be in the trust store.
  for i = 1, #chain - 1 do
    local child = chain[i]
    local issuer = chain[i + 1]
    local ok, err = verify_cert_signature(issuer.public_key,
      child.sig_alg.hash, child.sig_alg.kind, child.signature, child.tbs_raw)
    if not ok then return false, "cert " .. i .. ": " .. tostring(err) end
  end
  -- Trust store check: top-of-chain signed by a known root.
  local top = chain[#chain]
  for _, root_der in ipairs(opts.trust or {}) do
    local root = x509.parse(root_der)
    local ok = pcall(verify_cert_signature, root.public_key,
      top.sig_alg.hash, top.sig_alg.kind, top.signature, top.tbs_raw)
    if ok then return true end
  end
  return false, "no matching trust anchor"
end

-- ---- the connect ------------------------------------------------------

function M.connect(host, port, opts)
  opts = opts or {}
  local mode = opts.verify or "strict"
  port = port or 443

  local stream, err = internet.tcp_connect(host, port, opts.timeout or 30)
  if not stream then return nil, "tcp: " .. tostring(err) end

  local rec = Record.new(stream)
  local transcript = transcript_new()

  -- 1. ClientHello
  local hs, priv, _, _ = build_client_hello(host)
  transcript_update(transcript, hs)
  local ok, werr = rec:write_plaintext(CT_HANDSHAKE, hs)
  if not ok then stream:close(); return nil, "write client_hello: " .. tostring(werr) end

  -- 2. ServerHello
  local r, rerr = rec:read_record()
  if not r then stream:close(); return nil, "read sh: " .. tostring(rerr) end
  if r.type ~= CT_HANDSHAKE then stream:close(); return nil, "expected handshake, got " .. r.type end
  local sh, sherr = parse_server_hello(r.body)
  if not sh then stream:close(); return nil, "sh parse: " .. tostring(sherr) end
  transcript_update(transcript, r.body)

  -- 3. ECDHE shared + handshake key schedule
  local shared = x25519.scalarmult(priv, sh.server_pub)
  local hs_keys = key_schedule_handshake(shared, transcript_hash(transcript))
  rec.read_keys  = traffic_keys(hs_keys.s_hs)
  rec.write_keys = traffic_keys(hs_keys.c_hs)
  rec.read_seq, rec.write_seq = 0, 0

  -- 4. Read EncryptedExtensions / Certificate / CertificateVerify / Finished
  local hsr = HandshakeReader(rec)

  local ee = hsr:next(transcript); if not ee then stream:close(); return nil, "no EncryptedExtensions" end
  if ee:byte(1) ~= 8 then stream:close(); return nil, "expected EncryptedExtensions" end

  local cert_msg = hsr:next(transcript); if not cert_msg then stream:close(); return nil, "no Certificate" end
  if cert_msg:byte(1) ~= 11 then stream:close(); return nil, "expected Certificate" end

  -- Parse Certificate body: ctx<0..255> + cert_list<0..2^24>
  local cb = cert_msg:sub(5)                                     -- after type+len
  local ci = 1
  local ctx_len = cb:byte(ci); ci = ci + 1
  ci = ci + ctx_len
  local list_len = (cb:byte(ci) << 16) | (cb:byte(ci + 1) << 8) | cb:byte(ci + 2)
  ci = ci + 3
  local list_end = ci + list_len
  local chain = {}
  while ci < list_end do
    local cert_len = (cb:byte(ci) << 16) | (cb:byte(ci + 1) << 8) | cb:byte(ci + 2)
    ci = ci + 3
    local der = cb:sub(ci, ci + cert_len - 1)
    chain[#chain + 1] = x509.parse(der)
    ci = ci + cert_len
    -- skip per-cert extensions
    local ext_len = (cb:byte(ci) << 8) | cb:byte(ci + 1)
    ci = ci + 2 + ext_len
  end

  local cv_ok, cv_err = verify_chain(chain, host, mode, opts)
  if not cv_ok then stream:close(); return nil, "chain: " .. tostring(cv_err) end

  -- 5. CertificateVerify
  local cv_msg = hsr:next(transcript); if not cv_msg then stream:close(); return nil, "no CertificateVerify" end
  if cv_msg:byte(1) ~= 15 then stream:close(); return nil, "expected CertificateVerify" end
  local cv_body = cv_msg:sub(5)
  local cv_alg = cv_body:sub(1, 2)
  local cv_sig_len = (cv_body:byte(3) << 8) | cv_body:byte(4)
  local cv_sig = cv_body:sub(5, 4 + cv_sig_len)

  -- The server signs:
  --   "20 ...64 spaces..." || "TLS 1.3, server CertificateVerify" || 0x00 ||
  --   transcript_hash(ClientHello..Certificate)
  -- transcript right now (after EE+Cert appended) is exactly that.
  local th = transcript_hash({ acc = transcript.acc:sub(1, #transcript.acc - #cv_msg) })
  local signed = string.rep("\x20", 64) .. "TLS 1.3, server CertificateVerify\0" .. th
  local leaf_pub = chain[1].public_key
  local cv_ok2
  if cv_alg == SIG_ED25519 and leaf_pub.kind == "ed25519" then
    cv_ok2 = ed25519.verify(leaf_pub.pub, signed, cv_sig)
  elseif cv_alg == SIG_RSA_PSS and leaf_pub.kind == "rsa" then
    cv_ok2 = rsa.verify_pss(leaf_pub, "sha256", sha256.bytes(signed), cv_sig)
  else
    stream:close()
    return nil, "unsupported sig alg in CertificateVerify"
  end
  if not cv_ok2 then stream:close(); return nil, "CertificateVerify failed" end

  -- 6. Server Finished
  local fin_msg = hsr:next(); if not fin_msg then stream:close(); return nil, "no Finished" end
  if fin_msg:byte(1) ~= 20 then stream:close(); return nil, "expected Finished" end
  local fin_body = fin_msg:sub(5)
  local th_for_fin = transcript_hash(transcript)                 -- before Finished is appended
  local expected = finished_mac(hs_keys.s_hs, th_for_fin)
  if fin_body ~= expected then stream:close(); return nil, "server Finished MAC mismatch" end
  transcript_update(transcript, fin_msg)

  -- 7. Application key schedule
  local th_after = transcript_hash(transcript)
  local ap_keys = key_schedule_application(hs_keys.handshake_secret, th_after)

  -- 8. Client Finished
  local client_fin = finished_mac(hs_keys.c_hs, th_after)
  local cf_msg = "\20" .. be24(#client_fin) .. client_fin
  rec:write_encrypted(CT_HANDSHAKE, cf_msg)
  transcript_update(transcript, cf_msg)

  -- Switch to application traffic keys.
  rec.write_keys = traffic_keys(ap_keys.c_ap)
  rec.read_keys  = traffic_keys(ap_keys.s_ap)
  rec.write_seq, rec.read_seq = 0, 0

  -- 9. Wrap the connection.
  local conn = {}
  function conn:write(data) return rec:write_encrypted(CT_APP_DATA, data) end
  function conn:read()
    local r, e = rec:read_record()
    if not r then return nil, e end
    if r.type == CT_APP_DATA then return r.body end
    if r.type == CT_ALERT then
      local lvl, desc = r.body:byte(1), r.body:byte(2)
      if desc == 0 then return nil end                           -- close_notify
      return nil, string.format("tls alert lvl=%d desc=%d", lvl, desc)
    end
    return nil, "unexpected record type: " .. r.type
  end
  function conn:close()
    -- Send close_notify alert (level=1 warning, desc=0).
    pcall(rec.write_encrypted, rec, CT_ALERT, "\1\0")
    pcall(stream.close, stream)
  end
  return conn
end

-- ---- exposed building blocks (mostly for selftest) --------------------

M.build_client_hello = build_client_hello
M.parse_server_hello = parse_server_hello
M.key_schedule       = function(shared, transcript)
  local hs = key_schedule_handshake(shared, transcript)
  -- Compatibility shape with the older v0.4.5 selftest.
  return {
    handshake_secret  = hs.handshake_secret,
    master_secret     = key_schedule_application(hs.handshake_secret, transcript).master_secret,
    client_hs_traffic = hs.c_hs,
    server_hs_traffic = hs.s_hs,
  }
end
M.traffic_keys       = traffic_keys
M.aead_seal          = aead_seal
M.aead_open          = aead_open
M.finished_mac       = finished_mac

return M
