-- /bin/man — display a manual page through the pager.
--
-- Pages live under /etc/man/<section>/<name>.<section> (POSIX layout).
-- We search sections in order: 1 (user commands), 5 (config), 8 (admin).
-- Without a section the first match wins.
--
-- Usage:
--   man <name>           open the page named <name>
--   man <section> <name> open <name> from <section>
--   man -k <pattern>     search descriptions (apropos)

local args, _ = ...
local vfs   = require("k.vfs")
local pager = require("lib.devtools.pager")

local function err(msg) io.stderr:write("man: " .. msg .. "\n") end

local SECTIONS = { "1", "5", "8" }
local ROOT     = "/etc/man"

local function section_dirs()
  local out = {}
  for _, s in ipairs(SECTIONS) do out[#out + 1] = { s, ROOT .. "/" .. s } end
  return out
end

local function find_page(name, section)
  for _, sd in ipairs(section_dirs()) do
    if not section or section == sd[1] then
      local path = sd[2] .. "/" .. name .. "." .. sd[1]
      if vfs.exists(path) then return path, sd[1] end
    end
  end
end

local function apropos(pattern)
  local hits = {}
  pattern = pattern:lower()
  for _, sd in ipairs(section_dirs()) do
    local entries = vfs.list(sd[2]) or {}
    for _, n in ipairs(entries) do
      local path = sd[2] .. "/" .. n
      local body = vfs.read_all(path) or ""
      local first_line = body:match("^[^\n]*") or ""
      if (first_line .. " " .. n):lower():find(pattern, 1, true) then
        hits[#hits + 1] = string.format("%-16s (%s)  %s",
          n:gsub("%.%w+$", ""), sd[1], first_line:sub(1, 50))
      end
    end
  end
  return hits
end

if #args == 0 then
  err("usage: man <name> | man <section> <name> | man -k <pattern>")
  return 2
end

if args[1] == "-k" or args[1] == "--apropos" then
  if not args[2] then err("usage: man -k <pattern>"); return 2 end
  local hits = apropos(args[2])
  if #hits == 0 then err("nothing appropriate"); return 1 end
  for _, line in ipairs(hits) do print(line) end
  return 0
end

local section, name
if args[1]:match("^[1-9]$") then section, name = args[1], args[2]
else                                name = args[1] end
if not name then err("usage: man <name>"); return 2 end

local path, sec = find_page(name, section)
if not path then err("no manual entry for " .. name); return 1 end

local body = vfs.read_all(path) or ""
return pager.show(body, { title = string.format("%s(%s)", name, sec), always = true })
