-- /bin/git.lua — minimal git client (clone only).
--
-- Usage:
--   git clone <url> [<dest>]      shallow checkout of a public github repo
--
-- Only supports https://github.com/<user>/<repo>[.git] URLs. We don't
-- speak the real git protocol — instead we walk the GitHub trees API
-- and grab each blob via raw.githubusercontent.com. That's enough for
-- "I want to copy a small repo's source onto my OC machine"; full git
-- (pack files, smart protocol, history) is out of scope.
--
-- Branch defaults to `main`; pass `-b <branch>` to override.

local args, _ = ...
local internet = require("drv.internet")
local json     = require("lib.codec.json")
local vfs      = require("k.vfs")

local function usage() io.stderr:write("usage: git clone [-b <branch>] <url> [<dest>]\n"); return 2 end

local cmd = args[1]
if cmd ~= "clone" then return usage() end

local url, dest, branch
local i = 2
while i <= #args do
  local a = args[i]
  if a == "-b" or a == "--branch" then branch = args[i + 1]; i = i + 2
  elseif a:sub(1, 1) == "-" then io.stderr:write("git: unknown option: " .. a .. "\n"); return 2
  elseif not url then url  = a; i = i + 1
  else                dest = a; i = i + 1
  end
end
if not url then return usage() end
branch = branch or "main"

local user, repo = url:match("^https?://github%.com/([^/]+)/([^/%.]+)")
if not (user and repo) then
  io.stderr:write("git: only https://github.com/<user>/<repo>[.git] URLs are supported\n")
  return 1
end
dest = dest or repo
if not internet.has_internet() then
  io.stderr:write("git: no internet card / HTTP disabled\n"); return 1
end

local function http_get(target_url)
  local body, status, hdrs = internet.http_request(target_url, {
    headers = { ["User-Agent"] = "OCOS-git/0.1", ["Accept"] = "application/vnd.github+json" },
    timeout = 30,
  })
  if not body then return nil, "request: " .. tostring(status) end
  if type(status) == "number" and (status < 200 or status >= 300) then
    return nil, "HTTP " .. tostring(status)
  end
  return body, status, hdrs
end

io.write(string.format("Cloning %s/%s @ %s into %s ...\n", user, repo, branch, dest))

-- Resolve the branch to its tree SHA via the API. If `main` 404s, fall
-- back to `master` since older repos still use that as the default.
local tree_url = function(b)
  return string.format("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1",
    user, repo, b)
end

local body, err = http_get(tree_url(branch))
if not body and branch == "main" then
  io.write("  main not found, trying master ...\n")
  branch = "master"
  body, err = http_get(tree_url(branch))
end
if not body then io.stderr:write("git: " .. tostring(err) .. "\n"); return 1 end

local ok, tree = pcall(json.decode, body)
if not ok or type(tree) ~= "table" or not tree.tree then
  io.stderr:write("git: bad tree JSON\n"); return 1
end
if tree.truncated then
  io.stderr:write("git: warning — repo too large; tree was truncated by GitHub\n")
end

local raw_url = function(path)
  return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", user, repo, branch, path)
end

-- Make sure the destination directory exists.
pcall(vfs.mkdir, dest)

local function ensure_parent(path)
  local parts, cur = {}, ""
  for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
  for k = 1, #parts - 1 do
    cur = cur .. "/" .. parts[k]
    if not vfs.exists(cur) then pcall(vfs.mkdir, cur) end
  end
end

local n_blobs, failed = 0, 0
local total = 0
for _, entry in ipairs(tree.tree) do
  if entry.type == "blob" then total = total + 1 end
end

for _, entry in ipairs(tree.tree) do
  if entry.type == "tree" then
    local p = dest .. "/" .. entry.path
    if not vfs.exists(p) then pcall(vfs.mkdir, p) end
  elseif entry.type == "blob" then
    n_blobs = n_blobs + 1
    local p = dest .. "/" .. entry.path
    ensure_parent(p)
    io.write(string.format("\r  [%d/%d] %s%s", n_blobs, total, entry.path, string.rep(" ", 24)))
    local data, ferr = http_get(raw_url(entry.path))
    if not data then
      io.write("\n"); io.stderr:write("FAIL " .. entry.path .. ": " .. tostring(ferr) .. "\n")
      failed = failed + 1
    else
      local wok, werr = vfs.write_all(p, data)
      if not wok then
        io.write("\n"); io.stderr:write("FAIL write " .. entry.path .. ": " .. tostring(werr) .. "\n")
        failed = failed + 1
      end
    end
  end
end
io.write("\n")
if failed > 0 then
  io.stderr:write(string.format("git: %d/%d files failed\n", failed, total))
  return 1
end
print(string.format("Cloned %d files into %s", n_blobs, dest))
return 0
