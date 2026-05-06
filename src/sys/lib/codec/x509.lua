-- /sys/lib/codec/x509.lua — minimal X.509 v1/v3 certificate parser.
--
-- Built on lib/codec/asn1. We read just enough to:
--   * extract the subject public key (RSA n+e or Ed25519 raw bytes)
--   * surface the signature algorithm (OID) + signatureValue
--   * keep the raw bytes of the tbsCertificate so the signature can
--     be verified against it
--   * collect the subjectAltName DNS names for hostname matching
--
-- NOT parsed: extensions beyond SAN, name constraints, basicConstraints
-- (we just trust the chain length the caller passes), policies. For a
-- production-grade stack those would be added; for OCOS' first TLS
-- implementation they're out of scope.

local M = {}

local asn1 = require("lib.codec.asn1")

-- Common OIDs we recognise.
local OID = {
  rsa_encryption        = "1.2.840.113549.1.1.1",
  sha256_rsa            = "1.2.840.113549.1.1.11",
  sha384_rsa            = "1.2.840.113549.1.1.12",
  sha512_rsa            = "1.2.840.113549.1.1.13",
  rsa_pss               = "1.2.840.113549.1.1.10",
  ed25519               = "1.3.101.112",
  ec_public_key         = "1.2.840.10045.2.1",
  ec_p256               = "1.2.840.10045.3.1.7",
  ecdsa_sha256          = "1.2.840.10045.4.3.2",
  ecdsa_sha384          = "1.2.840.10045.4.3.3",
  ecdsa_sha512          = "1.2.840.10045.4.3.4",
  cn                    = "2.5.4.3",
  san                   = "2.5.29.17",
}

local SIG_ALG = {
  [OID.sha256_rsa]   = { kind = "rsa-pkcs1",  hash = "sha256" },
  [OID.sha384_rsa]   = { kind = "rsa-pkcs1",  hash = "sha384" },
  [OID.sha512_rsa]   = { kind = "rsa-pkcs1",  hash = "sha512" },
  [OID.rsa_pss]      = { kind = "rsa-pss",    hash = "sha256" },
  [OID.ed25519]      = { kind = "ed25519" },
  [OID.ecdsa_sha256] = { kind = "ecdsa-p256", hash = "sha256" },
  [OID.ecdsa_sha384] = { kind = "ecdsa-p256", hash = "sha384" },
  [OID.ecdsa_sha512] = { kind = "ecdsa-p256", hash = "sha512" },
}

local function read_seq(s, off)
  local n = asn1.read(s, off)
  if n.tag ~= 0x10 or n.primitive then
    error("x509: expected SEQUENCE at " .. off, 2)
  end
  return n
end

local function parse_algorithm_identifier(seq_node)
  -- AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY }
  local first = asn1.read(seq_node.body, 1)
  if first.tag ~= 0x06 then error("x509: missing algorithm OID") end
  return asn1.oid_to_string(first.body)
end

local function parse_rsa_public_key(bitstring_body)
  local _unused, payload = asn1.bitstring(bitstring_body)
  -- payload = SEQUENCE { n INTEGER, e INTEGER }
  local seq = asn1.read(payload, 1)
  if seq.tag ~= 0x10 then error("x509: rsa pubkey not a SEQUENCE") end
  local i = 1
  local n_node = asn1.read(seq.body, i); i = n_node.next_off
  local e_node = asn1.read(seq.body, i)
  if n_node.tag ~= 0x02 or e_node.tag ~= 0x02 then
    error("x509: rsa pubkey wrong tags")
  end
  local bigint = require("lib.codec.bigint")
  return {
    kind = "rsa",
    n = bigint.from_bytes(n_node.body),
    e = bigint.from_bytes(e_node.body),
  }
end

local function parse_ed25519_public_key(bitstring_body)
  local _unused, payload = asn1.bitstring(bitstring_body)
  if #payload ~= 32 then error("x509: ed25519 key must be 32 bytes") end
  return { kind = "ed25519", pub = payload }
end

local function parse_ec_public_key(alg_seq, bitstring_body)
  -- AlgorithmIdentifier: SEQUENCE { OID 1.2.840.10045.2.1, parameters = OID curveID }
  local oid_node    = asn1.read(alg_seq.body, 1)
  local params_node = asn1.read(alg_seq.body, oid_node.next_off)
  if params_node.tag ~= 0x06 then return { kind = "unsupported", oid = "ec-no-params" } end
  local curve = asn1.oid_to_string(params_node.body)
  if curve ~= OID.ec_p256 then
    return { kind = "unsupported", oid = "ec-curve:" .. curve }
  end
  -- subjectPublicKey is a BIT STRING containing 0x04 || X || Y (uncompressed).
  local _unused, payload = asn1.bitstring(bitstring_body)
  if payload:byte(1) ~= 0x04 or #payload ~= 65 then
    return { kind = "unsupported", oid = "ec-not-uncompressed" }
  end
  local bigint = require("lib.codec.bigint")
  return {
    kind = "ecdsa-p256",
    x = bigint.from_bytes(payload:sub(2, 33)),
    y = bigint.from_bytes(payload:sub(34, 65)),
  }
end

local function parse_subject_public_key_info(spki_seq)
  local i = 1
  local alg_seq = asn1.read(spki_seq.body, i); i = alg_seq.next_off
  local key_bs  = asn1.read(spki_seq.body, i)
  if key_bs.tag ~= 0x03 then error("x509: SPKI bit-string missing") end
  local oid = parse_algorithm_identifier(alg_seq)
  if oid == OID.rsa_encryption then
    return parse_rsa_public_key(key_bs.body)
  elseif oid == OID.ed25519 then
    return parse_ed25519_public_key(key_bs.body)
  elseif oid == OID.ec_public_key then
    return parse_ec_public_key(alg_seq, key_bs.body)
  end
  return { kind = "unsupported", oid = oid }
end

local function parse_name(seq_node)
  -- Subject is a Name = SEQUENCE OF RDN; we walk it just to grab the
  -- commonName string for diagnostics. Fancier name encoding (full
  -- printable form) isn't needed for verification.
  local cn
  for rdn in asn1.children(seq_node.body, 1) do
    -- rdn is a SET of AttributeTypeAndValue; walk children.
    if rdn.tag == 0x11 then                          -- SET
      for atv in asn1.children(rdn.body, 1) do       -- atv is SEQUENCE
        local ti = 1
        local oid_node = asn1.read(atv.body, ti); ti = oid_node.next_off
        local val_node = asn1.read(atv.body, ti)
        if asn1.oid_to_string(oid_node.body) == OID.cn then
          cn = val_node.body
        end
      end
    end
  end
  return cn
end

local function parse_extensions(extensions_node, info)
  -- extensions_node is the [3] EXPLICIT SEQUENCE OF Extension.
  -- Extension ::= SEQUENCE { extnID OID, critical BOOLEAN OPTIONAL, extnValue OCTET STRING }
  local seq = asn1.read(extensions_node.body, 1)
  for ext in asn1.children(seq.body, 1) do
    if ext.tag == 0x10 then
      local i = 1
      local oid = asn1.read(ext.body, i); i = oid.next_off
      local maybe = asn1.read(ext.body, i)
      if maybe.tag == 0x01 then i = maybe.next_off; maybe = asn1.read(ext.body, i) end
      local val = maybe.body                          -- OCTET STRING contents
      if asn1.oid_to_string(oid.body) == OID.san then
        local san_seq = asn1.read(val, 1)
        local names = {}
        for entry in asn1.children(san_seq.body, 1) do
          -- DNSName has tag class context-specific [2], primitive
          if entry.class == 2 and entry.tag == 2 then
            names[#names + 1] = entry.body
          end
        end
        info.dns_names = names
      end
    end
  end
end

function M.parse(der)
  -- Top-level Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
  local cert = read_seq(der, 1)
  local i = 1
  local tbs = asn1.read(cert.body, i); i = tbs.next_off
  local sig_alg_seq = asn1.read(cert.body, i); i = sig_alg_seq.next_off
  local sig_value   = asn1.read(cert.body, i)
  if tbs.tag ~= 0x10 then error("x509: tbsCertificate not SEQUENCE") end
  if sig_value.tag ~= 0x03 then error("x509: signatureValue not BIT STRING") end

  -- The TBS bytes are the section of the outer Certificate that the
  -- signature covers — we need them verbatim for the verify step.
  local tbs_start_in_outer = cert.hdr_end          -- start of tbs TLV in cert.body+offset
  -- Actually `tbs` was read out of cert.body at offset 1, so its raw
  -- range in `der` is [cert.hdr_end .. cert.hdr_end + (tbs.next_off-1) - 1].
  local tbs_raw = der:sub(cert.hdr_end,
                          cert.hdr_end + (tbs.next_off - 1) - 1)

  -- Walk the TBS body to extract subject, validity, SPKI, extensions.
  local ti = 1
  local first = asn1.read(tbs.body, ti)
  if first.class == 2 and first.tag == 0 then         -- [0] EXPLICIT version
    ti = first.next_off
  end
  local serial = asn1.read(tbs.body, ti); ti = serial.next_off
  local sig_alg_inner = asn1.read(tbs.body, ti); ti = sig_alg_inner.next_off
  local issuer = asn1.read(tbs.body, ti); ti = issuer.next_off
  local validity = asn1.read(tbs.body, ti); ti = validity.next_off
  local subject = asn1.read(tbs.body, ti); ti = subject.next_off
  local spki = asn1.read(tbs.body, ti); ti = spki.next_off
  local info = {
    issuer_cn  = parse_name(issuer),
    subject_cn = parse_name(subject),
    public_key = parse_subject_public_key_info(spki),
    sig_alg    = SIG_ALG[parse_algorithm_identifier(sig_alg_seq)] or
                 { kind = "unknown", oid = parse_algorithm_identifier(sig_alg_seq) },
    signature  = (function() local _, payload = asn1.bitstring(sig_value.body); return payload end)(),
    tbs_raw    = tbs_raw,
    dns_names  = {},
  }
  -- Extensions are optional and tagged [3].
  while ti <= #tbs.body do
    local node = asn1.read(tbs.body, ti); ti = node.next_off
    if node.class == 2 and node.tag == 3 then
      parse_extensions(node, info)
    end
  end
  return info
end

function M.matches_hostname(cert_info, host)
  -- Wildcard match per RFC 6125 — single leftmost label only.
  host = host:lower()
  local function match_one(pat)
    pat = pat:lower()
    if pat == host then return true end
    if pat:sub(1, 2) == "*." then
      local rest = pat:sub(3)
      local dot = host:find(".", 1, true)
      if dot then return host:sub(dot + 1) == rest end
    end
    return false
  end
  for _, n in ipairs(cert_info.dns_names or {}) do
    if match_one(n) then return true end
  end
  if cert_info.subject_cn and match_one(cert_info.subject_cn) then return true end
  return false
end

return M
