-- /sys/drv/data.lua — Data Card component wrapper.
--
-- Exposes T1/T2/T3 data-card primitives behind a cap-checked API:
--
--   T1   base64 / unbase64, crc32, md5
--   T2   sha256, hmac_sha256, hmac_md5, aes encrypt/decrypt, random
--   T2   deflate / inflate
--   T3   ecdsa: keygen, deserialize, ecdh, sign / verify
--
-- We pick the highest-tier card present at lookup time. Capability is
-- "component:data" — granted as a single token; the kernel does not split
-- per-method because the card semantics are uniform once you have it.
--
-- All methods return (result) or (nil, err). On a machine without a card
-- they return (nil, "no data card"). Pure-Lua fallbacks live in
-- /sys/lib/codec/ and stay independent of this driver — callers compose
-- them.

local M = {}

local cap = require("k.cap")

local function pick_card()
  -- Choose the card with the largest declared limit; that's a robust
  -- proxy for tier (T3 > T2 > T1) without having to read NBT.
  local best, best_limit
  for addr in component.list("data") do
    local proxy = component.proxy(addr)
    local ok, lim = pcall(proxy.getLimit)
    if ok and (not best_limit or lim > best_limit) then
      best, best_limit = proxy, lim
    end
  end
  return best
end

local function with_card(method)
  return function(...)
    local me = require("k.sched").current()
    local proc_caps = me and me.caps or { ["*"] = true }
    if not cap.check(proc_caps, "component:data",
        { user = me and me.name, action = method }) then
      return nil, "permission denied: component:data"
    end
    local card = pick_card()
    if not card then return nil, "no data card" end
    local fn = card[method]
    if not fn then return nil, "data card does not provide " .. method end
    local ok, result, extra = pcall(fn, ...)
    if not ok then return nil, tostring(result) end
    return result, extra
  end
end

-- ---- T1 ------------------------------------------------------------------
M.encode64 = with_card("encode64")
M.decode64 = with_card("decode64")
M.crc32    = with_card("crc32")
M.md5      = with_card("md5")

-- ---- T2 ------------------------------------------------------------------
M.sha256   = with_card("sha256")
M.hmac     = with_card("hmac")                     -- sha256/md5 picked by length
M.encrypt  = with_card("encrypt")                  -- AES (key, iv)
M.decrypt  = with_card("decrypt")
M.random   = with_card("random")
M.deflate  = with_card("deflate")
M.inflate  = with_card("inflate")

-- ---- T3 ------------------------------------------------------------------
M.generateKeyPair = with_card("generateKeyPair")
M.deserializeKey  = with_card("deserializeKey")
M.ecdh            = with_card("ecdh")
M.ecdsa           = with_card("ecdsa")             -- (data, priv) or (data, pub, sig)

function M.tier()
  local card = pick_card()
  if not card then return 0 end
  if card.generateKeyPair then return 3 end
  if card.encrypt          then return 2 end
  return 1
end

function M.has_card() return pick_card() ~= nil end

return M
