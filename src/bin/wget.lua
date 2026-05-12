-- /bin/wget.lua — fetch URLs via the OC internet card.
--
-- Behaviour matches GNU wget on the things people actually rely on:
--
--   * Without `-O`, the body is saved into the current directory under
--     the URL's basename (or `index.html` if the URL ends in `/`).
--     Earlier OCOS revisions wrote the body to stdout by default,
--     which made `wget URL` dump pages into the terminal — surprising
--     for anyone with GNU muscle memory.
--   * `-O FILE` saves to FILE; the literal `-` means stdout.
--   * Short options can be bundled: `wget -qO -` and `wget -qO file`
--     both work.
--   * Multiple URLs can be passed in one invocation.
--   * `--no-check-certificate` is accepted as a no-op (the OC internet
--     card already skips verification; we keep the flag for muscle
--     memory and for scripts copied from a Linux host).
--   * `--` ends option parsing.
--
-- Exit code: 0 on every 2xx response, 1 if any URL failed (network or
-- non-2xx), 2 on usage error.

local args, env = ...
local internet = require("drv.internet")
local fstream  = require("std.fstream")
local vfs      = require("k.vfs")
local getopt   = require("lib.getopt")

local SPEC = {
  O = "value",  output                = "O",
  P = "value", ["directory-prefix"]   = "P",
  q = "flag",   quiet                 = "q",
  S = "flag", ["server-response"]     = "S",
  ["no-check-certificate"]            = "flag",
  h = "flag",   help                  = "h",
}

local function usage(stream, code)
  stream = stream or io.stderr
  stream:write([[usage: wget [-q] [-O FILE] [-P DIR] [--no-check-certificate] URL...

Without -O, the body is saved into the current directory (or -P DIR)
under the URL's last path segment. `-O -` writes to stdout.
]])
  return code or 2
end

local opts, urls, err = getopt.parse(args, SPEC)
if err then io.stderr:write("wget: " .. err .. "\n"); return 2 end
if opts.h then return usage(io.stdout, 0) end
if #urls == 0 then return usage() end

if not internet.has_internet() then
  io.stderr:write("wget: no internet card / HTTP disabled\n"); return 1
end

local quiet = opts.q == true
local out_path = opts.O                                  -- nil / "-" / filename
local prefix   = opts.P or (env and env.PWD) or "/"
if prefix:sub(1, 1) ~= "/" then prefix = ((env and env.PWD) or "/") .. "/" .. prefix end
prefix = vfs.canonical(prefix)

local function basename_from_url(url)
  -- GNU wget: strip query (`?...`) and fragment (`#...`), then take
  -- the final path segment. A trailing slash → `index.html`.
  local path = url:match("^[%a][%w%+%.%-]*://[^/]+(.*)") or url
  path = path:gsub("[?#].*$", "")
  if path == "" or path:sub(-1) == "/" then return "index.html" end
  return path:match("([^/]+)$") or "index.html"
end

local function fetch_one(url)
  if not quiet then io.stderr:write("--  " .. url .. "\n") end
  local body, status = internet.http_request(url, { timeout = 30 })
  if not body then
    io.stderr:write("wget: " .. url .. ": " .. tostring(status) .. "\n")
    return 1
  end
  if type(status) == "number" and (status < 200 or status >= 300) then
    io.stderr:write("wget: " .. url .. ": HTTP " .. tostring(status) .. "\n")
    return 1
  end

  if out_path == "-" then
    io.stdout:write(body)
    if not quiet then
      io.stderr:write(string.format("  %d bytes to stdout\n", #body))
    end
    return 0
  end

  local dest
  if out_path then
    dest = out_path
    if dest:sub(1, 1) ~= "/" then dest = prefix .. "/" .. dest end
  else
    dest = prefix .. "/" .. basename_from_url(url)
  end
  dest = vfs.canonical(dest)

  local h, ferr = fstream.open(dest, "w")
  if not h then
    io.stderr:write("wget: " .. dest .. ": " .. tostring(ferr) .. "\n"); return 1
  end
  h:write(body); h:close()

  if not quiet then
    io.stderr:write(string.format("  saved %d bytes → %s\n", #body, dest))
  end
  return 0
end

local rc = 0
for _, url in ipairs(urls) do
  local code = fetch_one(url)
  if code ~= 0 then rc = 1 end
end
return rc
