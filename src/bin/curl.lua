-- /bin/curl.lua — minimal curl-style HTTP client.
--
-- Subset of GNU curl that covers the day-to-day shapes:
--
--   curl URL                          GET, body to stdout
--   curl -o FILE URL                  save body to FILE
--   curl -X POST -d 'k=v' URL         POST with raw body
--   curl -H 'Authorization: …' URL    extra header (repeatable)
--   curl -L URL                       follow up to 5 redirects
--   curl -i URL                       include the response status line
--   curl -s URL                       silent (no progress on stderr)
--   curl -sS URL                      silent, but still print errors
--   curl --tls-pure -k URL            pure-Lua TLS (lib/net/tls)
--
-- Short options bundle the GNU way: `-sSL`, `-sSLo file`, `-sSLofile`,
-- all parse correctly.

local args, _ = ...
local internet = require("drv.internet")
local fstream  = require("std.fstream")
local getopt   = require("lib.getopt")

local SPEC = {
  X = "value",  request                 = "X",
  H = "value",  header                  = "H",
  d = "value",  data                    = "d", ["data-raw"] = "d",
  o = "value",  output                  = "o",
  A = "value", ["user-agent"]           = "A",
  L = "flag",   location                = "L",
  i = "flag",   include                 = "i",
  s = "flag",   silent                  = "s",
  S = "flag", ["show-error"]            = "S",
  k = "flag",   insecure                = "k",
  ["tls-pure"]                          = "flag",
  h = "flag",   help                    = "h",
}

local function usage(stream, code)
  stream = stream or io.stderr
  stream:write([[usage: curl [-X METHOD] [-H 'K: V'] [-d BODY] [-o FILE]
            [-L] [-i] [-s] [-S] [-A AGENT] [--tls-pure] [-k] URL

  -X / --request          HTTP method (default GET; switches to POST
                          implicitly if -d is given without -X)
  -H / --header           extra request header (repeatable)
  -d / --data             request body; auto-switches to POST
  -o / --output           save body to FILE (default: stdout)
  -A / --user-agent       shortcut for `-H 'User-Agent: AGENT'`
  -L / --location         follow up to 5 redirects
  -i / --include          include the status line + headers in output
  -s / --silent           do not print progress on stderr
  -S / --show-error       with -s, still print errors
  --tls-pure              use OCOS's pure-Lua TLS (lib/net/tls) instead
                          of the OC internet card's native HTTPS
  -k / --insecure         with --tls-pure, skip cert chain verification
]])
  return code or 2
end

local opts, positional, perr = getopt.parse(args, SPEC)
if perr then io.stderr:write("curl: " .. perr .. "\n"); return 2 end
if opts.h then return usage(io.stdout, 0) end
if #positional == 0 then return usage() end
if #positional > 1 then
  io.stderr:write("curl: only one URL allowed (got " .. #positional .. ")\n"); return 2
end
local url = positional[1]
if not internet.has_internet() then
  io.stderr:write("curl: no internet card / HTTP disabled\n"); return 1
end

-- Headers come in twice: as a list (for outbound) and a table built
-- below (for retransmission to the driver, which wants a table).
local headers = {}
do
  local raw = opts.H
  if type(raw) == "string" then headers[#headers + 1] = raw end
  -- getopt collapses repeated values into the last one; we want all,
  -- so re-scan args for `-H`/`--header`. Tradeoff: small extra parse
  -- pass for the multi-value semantic that getopt intentionally
  -- doesn't bake in (most flags are single-value).
end
do
  headers = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-H" or a == "--header" then
      if args[i + 1] then headers[#headers + 1] = args[i + 1]; i = i + 2
      else i = i + 1 end
    elseif a:sub(1, 2) == "--" and a:sub(3, 8) == "header" then
      local v = a:match("=(.*)$"); if v then headers[#headers + 1] = v end
      i = i + 1
    else
      i = i + 1
    end
  end
end
if opts.A then headers[#headers + 1] = "User-Agent: " .. opts.A end

local method = opts.X or "GET"
local body = opts.d
if body and not opts.X then method = "POST" end
local out_path = opts.o
local follow   = opts.L == true
local include  = opts.i == true
local silent   = opts.s == true
local show_err = opts.S == true
local pure_tls = opts["tls-pure"] == true
local insecure = opts.k == true

local function fail(msg)
  if not silent or show_err then io.stderr:write("curl: " .. msg .. "\n") end
end

-- ---- pure-Lua TLS path -------------------------------------------------

local function pure_https(target_url)
  local tls = require("lib.net.tls")
  local scheme, host, rest = target_url:match("^(https?)://([^/]+)(.*)$")
  if not host then return nil, "bad URL" end
  if scheme ~= "https" then return nil, "--tls-pure only handles https://" end
  local port = 443
  local h, p = host:match("^([^:]+):(%d+)$"); if h then host = h; port = tonumber(p) end
  if rest == "" then rest = "/" end

  if not silent then io.stderr:write("→ " .. method .. " " .. target_url .. " (pure-Lua TLS)\n") end
  local conn, err = tls.connect(host, port, {
    verify  = insecure and "insecure" or "strict",
    timeout = 30,
  })
  if not conn then return nil, err end

  local req = { method .. " " .. rest .. " HTTP/1.1",
                "Host: " .. host,
                "User-Agent: curl/ocos",
                "Connection: close" }
  for _, hh in ipairs(headers) do req[#req + 1] = hh end
  if body then req[#req + 1] = "Content-Length: " .. #body end
  req[#req + 1] = ""; req[#req + 1] = body or ""
  conn:write(table.concat(req, "\r\n"))

  local parts = {}
  while true do
    local chunk, rerr = conn:read()
    if not chunk then
      if rerr then return nil, rerr end
      break
    end
    parts[#parts + 1] = chunk
  end
  conn:close()
  local resp = table.concat(parts)

  local sep = resp:find("\r\n\r\n", 1, true)
  if not sep then return nil, "malformed response" end
  local hdr = resp:sub(1, sep - 1)
  local data = resp:sub(sep + 4)
  local status_code = tonumber(hdr:match("^HTTP/%S+ (%d+)"))
  local resp_headers = {}
  for line in (hdr .. "\r\n"):gmatch("([^\r\n]+)\r\n") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then resp_headers[k] = v end
  end
  return data, status_code, resp_headers
end

local function once_native(target_url)
  local hdr_table = {}
  for _, h in ipairs(headers) do
    local k, v = h:match("^([^:]+):%s*(.*)$")
    if k then hdr_table[k] = v end
  end
  if not silent then io.stderr:write("→ " .. method .. " " .. target_url .. "\n") end
  return internet.http_request(target_url, {
    body    = body,
    headers = next(hdr_table) and hdr_table or nil,
    method  = method,
    timeout = 30,
  })
end

local data, status, resp_hdrs
local hops, current = 0, url
while true do
  if pure_tls then
    data, status, resp_hdrs = pure_https(current)
  else
    data, status, resp_hdrs = once_native(current)
  end
  if not data then fail(tostring(status)); return 1 end
  if follow and type(status) == "number" and status >= 300 and status < 400 and resp_hdrs then
    local target
    for k, v in pairs(resp_hdrs) do
      if k:lower() == "location" then
        target = type(v) == "table" and v[1] or v; break
      end
    end
    if not target then break end
    hops = hops + 1
    if hops > 5 then fail("too many redirects"); return 1 end
    if not silent then io.stderr:write("→ redirect: " .. target .. "\n") end
    current = target
  else
    break
  end
end

if include then
  io.write("HTTP/1.1 " .. tostring(status) .. "\n")
  if resp_hdrs then
    for k, v in pairs(resp_hdrs) do
      io.write(k .. ": " .. (type(v) == "table" and table.concat(v, ", ") or tostring(v)) .. "\n")
    end
  end
  io.write("\n")
end

if out_path and out_path ~= "-" then
  local h, ferr = fstream.open(out_path, "w")
  if not h then fail(tostring(ferr)); return 1 end
  h:write(data); h:close()
  if not silent then io.stderr:write(string.format("saved %d bytes → %s\n", #data, out_path)) end
else
  io.stdout:write(data)
end

if type(status) == "number" and (status < 200 or status >= 300) then return 1 end
return 0
