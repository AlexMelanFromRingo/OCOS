-- /sys/lib/codec/semver.lua — semantic-version parsing and constraints.
--
-- Versions are MAJOR.MINOR.PATCH (each numeric). Constraints are a comma-
-- separated list of operators on a target version:
--   "1.2.3"    -- exact
--   ">=1.2.3"  -- at-least
--   "<2.0.0"   -- less-than
--   "~1.2.3"   -- >=1.2.3, <1.3.0
--   "^1.2.3"   -- >=1.2.3, <2.0.0
--   "*"        -- any
-- A combined constraint like ">=1.0,<2.0" is satisfied iff every clause is.

local M = {}

function M.parse(s)
  if type(s) ~= "string" then return nil, "version must be a string" end
  local a, b, c = s:match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then
    a, b = s:match("^(%d+)%.(%d+)$")
    if a then c = "0"
    else
      a = s:match("^(%d+)$")
      if a then b = "0"; c = "0" end
    end
  end
  if not a then return nil, "not a version: " .. s end
  return { major = tonumber(a), minor = tonumber(b), patch = tonumber(c) }
end

local function compare(a, b)
  if a.major ~= b.major then return a.major < b.major and -1 or 1 end
  if a.minor ~= b.minor then return a.minor < b.minor and -1 or 1 end
  if a.patch ~= b.patch then return a.patch < b.patch and -1 or 1 end
  return 0
end
M.compare = compare

local function bump_major(v) return { major = v.major + 1, minor = 0, patch = 0 } end
local function bump_minor(v) return { major = v.major, minor = v.minor + 1, patch = 0 } end

local function clause_match(version, op, ref)
  local cmp = compare(version, ref)
  if op == "="  then return cmp == 0 end
  if op == ">=" then return cmp >= 0 end
  if op == "<=" then return cmp <= 0 end
  if op == ">"  then return cmp >  0 end
  if op == "<"  then return cmp <  0 end
  return false
end

local function parse_clause(c)
  c = c:gsub("^%s+", ""):gsub("%s+$", "")
  if c == "*" then return { kind = "any" } end
  local op, rest = c:match("^(>=)(.+)$")
  if not op then op, rest = c:match("^(<=)(.+)$") end
  if not op then op, rest = c:match("^(>)(.+)$") end
  if not op then op, rest = c:match("^(<)(.+)$") end
  if not op then op, rest = c:match("^(=)(.+)$") end
  if op then
    local v, err = M.parse(rest)
    if not v then return nil, err end
    return { kind = "op", op = op, ref = v }
  end
  if c:sub(1, 1) == "~" then
    local v, err = M.parse(c:sub(2))
    if not v then return nil, err end
    return { kind = "tilde", ref = v }
  end
  if c:sub(1, 1) == "^" then
    local v, err = M.parse(c:sub(2))
    if not v then return nil, err end
    return { kind = "caret", ref = v }
  end
  local v, err = M.parse(c)
  if not v then return nil, err end
  return { kind = "op", op = "=", ref = v }
end

local function clause_satisfies(version, clause)
  if clause.kind == "any" then return true end
  if clause.kind == "op" then return clause_match(version, clause.op, clause.ref) end
  if clause.kind == "tilde" then
    return clause_match(version, ">=", clause.ref)
       and clause_match(version, "<",  bump_minor(clause.ref))
  end
  if clause.kind == "caret" then
    return clause_match(version, ">=", clause.ref)
       and clause_match(version, "<",  bump_major(clause.ref))
  end
  return false
end

function M.satisfies(version_str, constraint_str)
  local v, err = M.parse(version_str); if not v then return nil, err end
  for clause_str in constraint_str:gmatch("[^,]+") do
    local clause, perr = parse_clause(clause_str)
    if not clause then return nil, perr end
    if not clause_satisfies(v, clause) then return false end
  end
  return true
end

return M
