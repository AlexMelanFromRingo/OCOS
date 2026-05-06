-- /bin/wget.lua — fetch a URL via the OC internet card.
--
-- Usage:
--   wget <url>             write to stdout
--   wget -O <path> <url>   write to <path>
--   wget -q <url>          suppress the progress line on stderr
--
-- Exits 0 on a 2xx response and 1 on any other condition. We rely on
-- /sys/drv/internet for the actual transport, which itself yields back
-- to the scheduler while waiting on the card's `finishConnect()` so the
-- watchdog never trips on a slow server.

local args, _ = ...
local internet = require("drv.internet")

local out_path
local quiet = false
local url
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-O" then
    out_path = args[i + 1]; i = i + 2
    if not out_path then io.stderr:write("wget: -O needs a path\n"); return 2 end
  elseif a == "-q" or a == "--quiet" then
    quiet = true; i = i + 1
  elseif a:sub(1, 1) == "-" then
    io.stderr:write("wget: unknown option: " .. a .. "\n"); return 2
  else
    if url then io.stderr:write("wget: only one URL allowed\n"); return 2 end
    url = a; i = i + 1
  end
end

if not url then
  io.stderr:write("usage: wget [-q] [-O <file>] <url>\n"); return 2
end

if not internet.has_internet() then
  io.stderr:write("wget: no internet card / HTTP disabled\n"); return 1
end

if not quiet then io.stderr:write("→ " .. url .. "\n") end
local body, status, headers = internet.http_request(url, { timeout = 30 })
if not body then
  io.stderr:write("wget: " .. tostring(status) .. "\n"); return 1
end
if type(status) == "number" and (status < 200 or status >= 300) then
  io.stderr:write("wget: HTTP " .. tostring(status) .. "\n"); return 1
end

if out_path then
  local fstream = require("std.fstream")
  local h, err = fstream.open(out_path, "w")
  if not h then io.stderr:write("wget: " .. tostring(err) .. "\n"); return 1 end
  h:write(body); h:close()
  if not quiet then
    io.stderr:write(string.format("saved %d bytes → %s\n", #body, out_path))
  end
else
  io.stdout:write(body)
end
return 0
