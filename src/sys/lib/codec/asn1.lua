-- /sys/lib/codec/asn1.lua — minimal ASN.1 DER reader.
--
-- Just enough to parse X.509 certificates: TLV decoding for the
-- universal-class tags that show up in cert structures (INTEGER,
-- OBJECT IDENTIFIER, BIT STRING, OCTET STRING, NULL, SEQUENCE, SET,
-- UTF8String, PrintableString, IA5String, UTCTime, GeneralizedTime,
-- plus context-specific tags via raw_decode).
--
-- API:
--   asn1.read(s, off)              -> { tag, class, primitive, body, len, hdr_end, next_off }
--   asn1.children(s, parent_off)   -> iterator over the SEQUENCE/SET children
--   asn1.oid_to_string(bytes)      -> "1.2.840.113549.1.1.11"
--   asn1.integer(bytes)            -> Lua number for small ints, big-endian byte string otherwise
--   asn1.bitstring(bytes)          -> trailing bits + payload string

local M = {}

local function err(msg, off) error(string.format("asn1: %s at offset %d", msg, off or 0), 2) end

function M.read(s, off)
  off = off or 1
  if off > #s then err("eof", off) end
  local tag = s:byte(off)
  local cls = (tag >> 6) & 0x03                     -- 0=universal, 1=app, 2=ctx, 3=priv
  local primitive = (tag & 0x20) == 0
  local tag_num = tag & 0x1F
  local i = off + 1
  if tag_num == 0x1F then                            -- multi-byte tag (rare in X.509)
    tag_num = 0
    while true do
      if i > #s then err("eof in long tag", off) end
      local b = s:byte(i); i = i + 1
      tag_num = (tag_num << 7) | (b & 0x7F)
      if (b & 0x80) == 0 then break end
    end
  end
  if i > #s then err("eof before length", off) end
  local b = s:byte(i); i = i + 1
  local len
  if (b & 0x80) == 0 then
    len = b
  else
    local nb = b & 0x7F
    if nb == 0 then err("indefinite length not supported in DER", off) end
    if i + nb - 1 > #s then err("eof in length", off) end
    len = 0
    for _ = 1, nb do len = (len << 8) | s:byte(i); i = i + 1 end
  end
  if i + len - 1 > #s then err("eof in body", off) end
  local body = s:sub(i, i + len - 1)
  return {
    tag        = tag_num,
    class      = cls,
    primitive  = primitive,
    body       = body,
    len        = len,
    hdr_end    = i,                                  -- first byte of body
    next_off   = i + len,
  }
end

function M.children(s, parent_off)
  -- parent_off is the start of a SEQUENCE/SET TLV; iterate over the
  -- direct children inside its body.
  local node = M.read(s, parent_off)
  if node.primitive then return function() return nil end end
  local i = node.hdr_end
  local stop = node.next_off
  return function()
    if i >= stop then return nil end
    local child = M.read(s, i)
    i = child.next_off
    return child
  end
end

function M.integer(bytes)
  -- Small integers fit in Lua. Larger ones are returned as a big-endian
  -- byte string so callers (RSA pubkey n / e) can treat them as bigint
  -- without losing the leading-zero trimming DER mandates.
  if #bytes <= 8 then
    local n = 0
    if bytes:byte(1) >= 0x80 then n = -1 end         -- two's complement extend
    for i = 1, #bytes do n = ((n << 8) | bytes:byte(i)) & 0xFFFFFFFFFFFFFFFF end
    return n
  end
  -- Strip a single 0x00 padding byte that DER prepends to keep INTEGERs
  -- positive when the high bit would otherwise indicate negative.
  if bytes:byte(1) == 0x00 then bytes = bytes:sub(2) end
  return bytes
end

function M.oid_to_string(bytes)
  if #bytes == 0 then return "" end
  local first = bytes:byte(1)
  local out = { tostring(first // 40), tostring(first % 40) }
  local i, n, acc = 2, #bytes, 0
  while i <= n do
    local b = bytes:byte(i); i = i + 1
    acc = (acc << 7) | (b & 0x7F)
    if (b & 0x80) == 0 then
      out[#out + 1] = tostring(acc); acc = 0
    end
  end
  return table.concat(out, ".")
end

function M.bitstring(bytes)
  -- DER bitstring: first byte = number of unused trailing bits.
  local unused = bytes:byte(1) or 0
  return unused, bytes:sub(2)
end

function M.utctime(s)
  -- "YYMMDDHHMMSSZ" (13 chars) — return year/month/day/h/m/s; year
  -- 50..99 → 19xx, else 20xx.
  local y, m, d, h, mi, sec = s:match("^(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)Z$")
  if not y then return nil end
  y = tonumber(y); if y >= 50 then y = y + 1900 else y = y + 2000 end
  return { year = y, month = tonumber(m), day = tonumber(d),
           hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) }
end

function M.generalizedtime(s)
  local y, m, d, h, mi, sec = s:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)Z$")
  if not y then return nil end
  return { year = tonumber(y), month = tonumber(m), day = tonumber(d),
           hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) }
end

return M
