-- /sys/lib/sh/complete.lua — Tab completion for the interactive shell.
--
-- Returns a closure(prefix, full_line, cursor) → list of completions, where
-- the *first* word completes from $PATH (executables) plus shell builtins,
-- and any subsequent word completes filesystem paths relative to PWD.
--
-- The closure is dependency-injected with the shell state so PATH / PWD
-- changes are reflected without re-creating it.

local M = {}

local vfs      = require("k.vfs")
local builtins = require("lib.sh.builtins")

local function token_under_cursor(prefix)
  -- Naïve splitter: spaces separate words. Quotes are not respected, which
  -- is acceptable for a completion hint — the shell parser owns real
  -- tokenisation when the line is submitted.
  local last_space = prefix:reverse():find(" ", 1, true)
  if not last_space then return prefix, 0 end
  local cut = #prefix - last_space + 1
  return prefix:sub(cut + 1), cut
end

local function list_dir(path)
  local entries = vfs.list(path)
  if not entries then return nil end
  local out = {}
  for _, name in ipairs(entries) do out[#out + 1] = name end
  table.sort(out)
  return out
end

local function complete_path(token, shell)
  local pwd = shell.env.PWD or "/"
  local raw = token
  if raw:sub(1, 1) ~= "/" then raw = pwd .. "/" .. raw end
  local dir, base = raw:match("^(.*)/([^/]*)$")
  if not dir then dir, base = "/", raw end
  if dir == "" then dir = "/" end
  dir = vfs.canonical(dir)
  local entries = list_dir(dir)
  if not entries then return {} end
  local out = {}
  for _, name in ipairs(entries) do
    local clean = name:gsub("/$", "")
    if clean:sub(1, #base) == base then
      local trail = vfs.isdir(dir == "/" and ("/" .. clean) or (dir .. "/" .. clean)) and "/" or ""
      out[#out + 1] = clean .. trail
    end
  end
  return out
end

local function commands_in_path(path_var)
  local seen, out = {}, {}
  for dir in (path_var or "/bin"):gmatch("[^:]+") do
    local entries = vfs.list(dir)
    if entries then
      for _, name in ipairs(entries) do
        local clean = name:gsub("/$", "")
        local cmd = clean:gsub("%.lua$", "")
        if not seen[cmd] then
          seen[cmd] = true
          out[#out + 1] = cmd
        end
      end
    end
  end
  for k in pairs(builtins) do
    if not seen[k] then seen[k] = true; out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

local function complete_command(token, shell)
  local cmds = commands_in_path(shell.env.PATH)
  local out = {}
  for _, c in ipairs(cmds) do
    if c:sub(1, #token) == token then out[#out + 1] = c end
  end
  return out
end

function M.for_shell(shell)
  return function(prefix)
    local token, prefix_cut = token_under_cursor(prefix)
    local matches
    if prefix_cut == 0 then
      matches = complete_command(token, shell)
    else
      matches = complete_path(token, shell)
    end
    -- Returning the head + completion as a string lets read_line know the
    -- replacement is the *whole prefix* — but we want the editor to keep
    -- everything before the token and just substitute the token suffix. So
    -- always return a list; the editor's common-prefix logic will fill in
    -- the shared characters. When there's exactly one match we still
    -- return a list of one so the editor finishes the token in place.
    if #matches == 0 then return {} end
    -- The console editor compares its `prefix` string to common-prefix of
    -- candidates; we therefore prepend the un-completed head so the math
    -- works out and the editor only inserts the new suffix.
    local head = prefix:sub(1, prefix_cut)
    local out = {}
    for i, m in ipairs(matches) do out[i] = head .. m end
    return out
  end
end

return M
