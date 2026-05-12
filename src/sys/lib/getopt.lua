-- /sys/lib/getopt.lua — small POSIX/GNU-style option parser for /bin tools.
--
-- Handles the things we kept getting wrong by hand in each /bin script:
--   * short option bundling: `-qO file` and `-qO-` both split into
--     `-q` + `-O` (or `-q` + `-O -` if the cluster runs out).
--   * `--long=value` and `--long value` forms.
--   * `--` ends option parsing; everything after is positional.
--   * a leading `-` is a positional (the conventional "stdin" marker
--     used by cat, wc, head, tail).
--
-- Spec is a table that maps option name (without leading `-`) to one
-- of two markers:
--
--     "flag"   -- boolean, no value
--     "value"  -- consumes the next argument (or the rest of a short
--                 cluster) as its value
--
-- Aliases are declared by setting an entry to another spec key:
--
--     local spec = {
--       o = "value",      -- canonical
--       output = "o",     -- alias: --output / --output=X writes opts.o
--       q = "flag",       -- canonical
--       quiet = "q",      -- alias: --quiet writes opts.q
--     }
--
-- The parser returns (opts, positional, err). `opts` is keyed by the
-- canonical short name when present, otherwise the long name; `err`
-- is a string when something went wrong (caller usually prints + exits).
--
-- Usage example:
--   local opts, pos, err = getopt.parse(args, {
--     O = "value", o = "value",
--     q = "flag",  S = "flag",
--     ["no-check-certificate"] = "flag",
--   })

local M = {}

local function classify(spec, name)
  -- A name may resolve via direct spec entry or via an _alias_<name>
  -- pointer. Returns the canonical key and whether it takes a value.
  if spec[name] then
    if spec[name] == "flag" or spec[name] == "value" then
      return name, spec[name] == "value"
    end
    -- value is an alias pointer: spec[name] = "real-name"
    return classify(spec, spec[name])
  end
  return nil, nil
end

function M.parse(args, spec)
  local opts, positional = {}, {}
  local i, end_of_opts = 1, false

  while i <= #args do
    local a = args[i]
    if end_of_opts then
      positional[#positional + 1] = a; i = i + 1
    elseif a == "--" then
      end_of_opts = true; i = i + 1
    elseif a == "-" or a:sub(1, 1) ~= "-" then
      positional[#positional + 1] = a; i = i + 1
    elseif a:sub(1, 2) == "--" then
      -- long option, possibly --key=value
      local name, eq_val = a:sub(3):match("^([^=]+)=?(.*)$")
      if eq_val == "" then eq_val = nil end
      local key, takes_val = classify(spec, name)
      if not key then return nil, nil, "unknown option: --" .. name end
      if takes_val then
        if eq_val then
          opts[key] = eq_val; i = i + 1
        else
          if not args[i + 1] then return nil, nil, "--" .. name .. " needs a value" end
          opts[key] = args[i + 1]; i = i + 2
        end
      else
        if eq_val then return nil, nil, "--" .. name .. " takes no value" end
        opts[key] = true; i = i + 1
      end
    else
      -- short cluster like -qO, -O-, -qOfile
      local cluster = a:sub(2)
      local j = 1
      while j <= #cluster do
        local ch = cluster:sub(j, j)
        local key, takes_val = classify(spec, ch)
        if not key then return nil, nil, "unknown option: -" .. ch end
        if takes_val then
          local rest = cluster:sub(j + 1)
          if rest ~= "" then
            opts[key] = rest; j = #cluster + 1
          else
            if not args[i + 1] then return nil, nil, "-" .. ch .. " needs a value" end
            opts[key] = args[i + 1]; i = i + 1; j = #cluster + 1
          end
        else
          opts[key] = true; j = j + 1
        end
      end
      i = i + 1
    end
  end

  return opts, positional, nil
end

return M
