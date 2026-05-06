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
  elseif a:sub(1, 1) == "-" then
    io.stderr:write("curl: unknown option: " .. a .. "\n"); return 2
  else
    if url then io.stderr:write("curl: only one URL allowed\n"); return 2 end
    url = a; i = i + 1
  end
end

if not url then
  io.stderr:write("usage: curl [-X METHOD] [-H 'K: V'] [-d BODY] [-o FILE] [-L] [-s] <url>\n")
  return 2
end
if not internet.has_internet() then
  io.stderr:write("curl: no internet card / HTTP disabled\n"); return 1
end

-- The driver's http_request takes opts.method but it ignores it on the
-- OC native side — the card always issues whatever method the body
-- presence implies (GET when body=nil, POST otherwise). We pass body
-- as a string so the card honours the user's choice.
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
  data, status, resp_hdrs = once(current)
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
