-- /bin/ls.lua — list directory contents.
--
-- Type-coloured output when stdout is a TTY (the stream stamps itself
-- with _isatty = true), otherwise plain. The colour scheme echoes a
-- conventional shell ls so muscle memory works:
--
--   directory        bright blue
--   executable .lua  green
--   image / ocif     magenta
--   archive / ocpkg  red
--   config / .cfg    yellow
--   hidden (.X)      muted grey
--   plain            default

local args, env = ...
local vfs     = require("k.vfs")
local console = require("lib.term.console")

local DIR_FG     = 0x4FA0F0
local EXEC_FG    = 0x66DD66
local IMAGE_FG   = 0xCC66CC
local ARCHIVE_FG = 0xE05050
local CONFIG_FG  = 0xE0C040
local HIDDEN_FG  = 0x808080

local function classify(name, full)
  if vfs.isdir(full) then return "dir" end
  if name:sub(1, 1) == "."     then return "hidden" end
  local ext = name:match("%.([^.]+)$")
  if not ext then return "plain" end
  ext = ext:lower()
  if ext == "lua" then
    if full:find("^/bin/") or full:find("^/sbin/") then return "exec" end
    return "exec"
  end
  if ext == "cfg" or ext == "ini" or ext == "toml" then return "config" end
  if ext == "png" or ext == "ocif" or ext == "ocbm" then return "image" end
  if ext == "tar" or ext == "gz" or ext == "ocpkg" or ext == "zip" then return "archive" end
  return "plain"
end

local FG = {
  dir     = DIR_FG,    exec    = EXEC_FG,
  image   = IMAGE_FG,  archive = ARCHIVE_FG,
  config  = CONFIG_FG, hidden  = HIDDEN_FG,
  plain   = nil,
}

local long, all, want_color = false, false, "auto"
local end_of_opts = false
local positional = {}
for _, a in ipairs(args) do
  if end_of_opts then positional[#positional + 1] = a
  elseif a == "--" then end_of_opts = true
  elseif a == "--color=always" then want_color = "always"
  elseif a == "--color=never"  then want_color = "never"
  elseif a == "--color" or a == "--color=auto" then want_color = "auto"
  elseif a:sub(1, 1) == "-" and #a > 1 then
    -- Bundle: -la, -al, -laQ, etc. Walk each character; unknown
    -- chars fail the whole invocation rather than getting silently
    -- treated as a path (matches GNU coreutils).
    for j = 2, #a do
      local c = a:sub(j, j)
      if c == "l" then long = true
      elseif c == "a" then all = true
      else io.stderr:write("ls: unknown option: -" .. c .. "\n"); return 2 end
    end
  else positional[#positional + 1] = a end
end

local function resolve_path(p)
  if not p then return env.PWD or "/" end
  if p:sub(1, 1) ~= "/" then p = vfs.canonical((env.PWD or "/") .. "/" .. p) end
  return p
end

if #positional == 0 then positional[1] = env.PWD or "/" end

local out = io.stdout
local use_color = (want_color == "always") or (want_color == "auto" and (out._isatty or out._ansi))

-- Map our 0xRRGGBB shades to the closest ANSI 8-colour fg code so a
-- terminal that only knows `\x1b[31m` style still gets the right hue.
local ANSI_FG_FOR = {
  [0x4FA0F0] = 94,   -- dir       → bright blue
  [0x66DD66] = 92,   -- exec      → bright green
  [0xCC66CC] = 95,   -- image     → bright magenta
  [0xE05050] = 91,   -- archive   → bright red
  [0xE0C040] = 93,   -- config    → bright yellow
  [0x808080] = 90,   -- hidden    → bright black (grey)
}

local function emit(name, kind)
  -- The colour already tells the user this is a directory; no trailing
  -- slash, the white "/" after a coloured name looked off-balance.
  if use_color then
    local fg = FG[kind]
    if fg then
      if out._ansi then
        out:write(string.format("\27[%dm%s\27[0m", ANSI_FG_FOR[fg] or 39, name))
      else
        local prev = console.fg()
        console.set_fg(fg); out:write(name); console.set_fg(prev)
      end
    else
      out:write(name)
    end
    out:write("\n")
  else
    out:write(name .. "\n")
  end
end

local function emit_long(name, kind, full)
  local size = vfs.size(full) or 0
  local mtime = vfs.lastmod(full) or 0
  local mark  = kind == "dir" and "d" or "-"
  io.stdout:write(string.format("%s %10d %10d  ", mark, size, mtime))
  emit(name, kind)
end

local function list_one(path, show_header)
  if not vfs.exists(path) then
    io.stderr:write("ls: not found: " .. path .. "\n"); return 1
  end
  if not vfs.isdir(path) then
    print(path); return 0
  end
  local entries, err = vfs.list(path)
  if not entries then
    io.stderr:write("ls: " .. tostring(err) .. "\n"); return 1
  end
  for i, name in ipairs(entries) do entries[i] = (name:gsub("/$", "")) end
  table.sort(entries)
  if show_header then io.write(path .. ":\n") end
  for _, name in ipairs(entries) do
    if all or name:sub(1, 1) ~= "." then
      local full = path == "/" and ("/" .. name) or (path .. "/" .. name)
      local kind = classify(name, full)
      if long then emit_long(name, kind, full) else emit(name, kind) end
    end
  end
  return 0
end

local rc = 0
for i, p in ipairs(positional) do
  local resolved = resolve_path(p)
  if i > 1 then io.write("\n") end
  local code = list_one(resolved, #positional > 1)
  if code ~= 0 then rc = code end
end
return rc
