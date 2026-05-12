-- /bin/cat.lua — concatenate files (or stdin) to stdout.
--
-- Spec parity with GNU cat on the things scripts use:
--   * `-` as a filename reads stdin.
--   * `--` ends options.
--   * Files are resolved against env.PWD.
--
-- We intentionally don't implement -n / -A / -E etc.; OCOS scripts that
-- want line numbering pipe through `wc -l` or use `head -n`.

local args, env = ...
local vfs = require("k.vfs")

local end_of_opts = false
local files = {}
for _, a in ipairs(args) do
  if end_of_opts then files[#files + 1] = a
  elseif a == "--" then end_of_opts = true
  elseif a == "-" then files[#files + 1] = a
  elseif a:sub(1, 1) == "-" then
    io.stderr:write("cat: unknown option: " .. a .. "\n"); return 2
  else files[#files + 1] = a end
end

local function dump_stream(stream)
  while true do
    local chunk = stream:read(4096)
    if not chunk or chunk == "" then break end
    io.write(chunk)
  end
end

if #files == 0 then dump_stream(io.stdin); return 0 end

local rc = 0
for _, name in ipairs(files) do
  if name == "-" then
    dump_stream(io.stdin)
  else
    local path = name:sub(1, 1) == "/" and name
      or vfs.canonical(((env and env.PWD) or "/") .. "/" .. name)
    local h, err = vfs.open(path, "r")
    if not h then
      io.stderr:write("cat: " .. name .. ": " .. tostring(err) .. "\n"); rc = 1
    else
      dump_stream(h); h:close()
    end
  end
end
return rc
