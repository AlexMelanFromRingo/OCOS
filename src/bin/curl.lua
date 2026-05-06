-- /bin/curl.lua — minimal curl-style HTTP client.
--
-- Usage (subset):
--   curl <url>                     GET, body to stdout
--   curl -o <path> <url>           save body to <path>
--   curl -X POST -d <data> <url>   POST with body
--   curl -H "K: V" <url>           extra header (repeatable)
--   curl -L <url>                  follow up to 5 redirects
--   curl -i <url>                  include the response status line
--   curl -sS <url>                 silent (no progress to stderr)
--
-- Built on /sys/drv/internet's http_request — same path pkg-install
-- uses. HTTPS works as long as the OC internet card is configured to
-- allow it (config flag `enableTLS`/`enableHttps` in the host config),
-- which is the default in modern OC builds.

local args, _ = ...
local internet = require("drv.internet")

local headers     = {}
local method      = "GET"
local body
local out_path
local follow      = false
local include     = false
local silent      = false
local pure_tls    = false
local insecure    = false
local url

local function shift(i)
  local v = args[i]
  if v == nil then io.stderr:write("curl: missing value after option\n"); os.exit(2) end
  return v
end

local i = 1
while i <= #args do
  local a = args[i]
  if a == "-X" or a == "--request" then
    method = shift(i + 1); i = i + 2
  elseif a == "-H" or a == "--header" then
    headers[#headers + 1] = shift(i + 1); i = i + 2
  elseif a == "-d" or a == "--data" or a == "--data-raw" then
    body = shift(i + 1); i = i + 2
    if method == "GET" then method = "POST" end
  elseif a == "-o" or a == "--output" then
    out_path = shift(i + 1); i = i + 2
  elseif a == "-L" or a == "--location" then
    follow = true; i = i + 1
  elseif a == "-i" or a == "--include" then
    include = true; i = i + 1
  elseif a == "-s" or a == "-sS" or a == "--silent" then
    silent = true; i = i + 1
  elseif a == "-A" or a == "--user-agent" then
    headers[#headers + 1] = "User-Agent: " .. shift(i + 1); i = i + 2
  elseif a == "--tls-pure" then
    pure_tls = true; i = i + 1
  elseif a == "-k" or a == "--insecure" then
    insecure = true; i = i + 1
  elseif a:sub(1, 1) == "-" then
    io.stderr:write("curl: unknown option: " .. a .. "\n"); return 2
  else
    if url then io.stderr:write("curl: only one URL allowed\n"); return 2 end
    url = a; i = i + 1
  end
end

if not url then
  io.stderr:write([[usage: curl [-X METHOD] [-H 'K: V'] [-d BODY] [-o FILE] [-L] [-s] [--tls-pure] [-k] <url>

  --tls-pure   use OCOS pure-Lua TLS (lib/net/tls) instead of OC's
               native HTTPS — useful when the OC server has TLS
               disabled or you want signature verification done by
               OCOS's own crypto stack.
  -k           with --tls-pure, skip cert chain verification
               (still verifies CertificateVerify and Finished MAC).

]])
  return 2
end
if not internet.has_internet() then
  io.stderr:write("curl: no internet card / HTTP disabled\n"); return 1
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

  -- Build HTTP/1.1 request.
  local req = { method .. " " .. rest .. " HTTP/1.1",
                "Host: " .. host,
                "User-Agent: curl/ocos",
                "Connection: close" }
  for _, hh in ipairs(headers) do req[#req + 1] = hh end
  if body then
    req[#req + 1] = "Content-Length: " .. #body
  end
  req[#req + 1] = ""; req[#req + 1] = body or ""
  local raw = table.concat(req, "\r\n")
  conn:write(raw)

  -- Read until close_notify / EOF.
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

  -- Split status line + headers + body.
  local sep = resp:find("\r\n\r\n", 1, true)
  if not sep then return nil, "malformed response" end
  local hdr = resp:sub(1, sep - 1)
  local data = resp:sub(sep + 4)
  local status_line = hdr:match("^(HTTP/%S+ %d+ [^\r\n]*)")
  local status_code = tonumber(hdr:match("^HTTP/%S+ (%d+)"))
  local resp_headers = {}
  for line in (hdr .. "\r\n"):gmatch("([^\r\n]+)\r\n") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then resp_headers[k] = v end
  end
  return data, status_code, resp_headers, status_line
end

-- The driver's http_request takes opts.method but it ignores it on the
-- OC native side — the card always issues whatever method the body
-- presence implies (GET when body=nil, POST otherwise). We pass body
-- as a string so the card honours the user's choice.
local function once_pure(target_url)
  local data, status, hdrs = pure_https(target_url)
  return data, status, hdrs
end

local function once(target_url)
  local hdr_table = {}
  for _, h in ipairs(headers) do
    local k, v = h:match("^([^:]+):%s*(.*)$")
    if k then hdr_table[k] = v end
  end
  if not silent then io.stderr:write("→ " .. method .. " " .. target_url .. "\n") end
  local data, status, resp_hdrs = internet.http_request(target_url, {
    body    = body,
    headers = next(hdr_table) and hdr_table or nil,
    method  = method,
    timeout = 30,
  })
  return data, status, resp_hdrs
end

local data, status, resp_hdrs
local hops = 0
local current = url
while true do
  if pure_tls then
    data, status, resp_hdrs = once_pure(current)
  else
    data, status, resp_hdrs = once(current)
  end
  if not data then
    io.stderr:write("curl: " .. tostring(status) .. "\n"); return 1
  end
  if follow and type(status) == "number" and status >= 300 and status < 400 and resp_hdrs then
    -- Find Location: header in response (case-insensitive).
    local target
    for k, v in pairs(resp_hdrs) do
      if k:lower() == "location" then
        target = type(v) == "table" and v[1] or v; break
      end
    end
    if not target then break end
    hops = hops + 1
    if hops > 5 then io.stderr:write("curl: too many redirects\n"); return 1 end
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

if out_path then
  local fstream = require("std.fstream")
  local h, ferr = fstream.open(out_path, "w")
  if not h then io.stderr:write("curl: " .. tostring(ferr) .. "\n"); return 1 end
  h:write(data); h:close()
  if not silent then io.stderr:write(string.format("saved %d bytes → %s\n", #data, out_path)) end
else
  io.stdout:write(data)
end

if type(status) == "number" and (status < 200 or status >= 300) then return 1 end
return 0
