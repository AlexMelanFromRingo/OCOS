-- /sys/lib/sh/lexer.lua — POSIX-ish shell tokenizer.
--
-- Produces a stream of typed tokens for the parser:
--   {type="word",  parts={{kind="lit"|"var", value|name}, ...}}
--   {type="pipe"}                      |
--   {type="and"}                       &&
--   {type="or"}                        ||
--   {type="semi"}                      ;
--   {type="redir", op=">"|">>"|"<"|"2>"}
--
-- A "word" is a list of literal/variable segments — expansion is the parser
-- and runtime's job, the lexer only marks where each segment came from. This
-- keeps quoting/escape rules localised to one place.

local M = {}

local function isspace(c) return c == " " or c == "\t" end

local function parse_var(src, pos)
  -- pos already points past the leading '$'. Returns (name, length consumed
  -- after the '$', including any braces).
  if src:sub(pos, pos) == "{" then
    local close = src:find("}", pos + 1, true)
    if not close then return nil end
    return src:sub(pos + 1, close - 1), close - pos + 1
  end
  local stop = pos
  while stop <= #src do
    local c = src:sub(stop, stop)
    if not c:match("[%w_]") then break end
    stop = stop + 1
  end
  if stop == pos then return nil end
  return src:sub(pos, stop - 1), stop - pos
end

function M.lex(src)
  local tokens = {}
  local pos, n = 1, #src
  local word

  local function flush()
    if word then
      tokens[#tokens + 1] = { type = "word", parts = word }
      word = nil
    end
  end

  local function lit(s)
    word = word or {}
    local last = word[#word]
    if last and last.kind == "lit" then
      last.value = last.value .. s
    else
      word[#word + 1] = { kind = "lit", value = s }
    end
  end

  local function var(name)
    word = word or {}
    word[#word + 1] = { kind = "var", name = name }
  end

  while pos <= n do
    local c = src:sub(pos, pos)
    if isspace(c) then
      flush(); pos = pos + 1
    elseif c == "#" and not word then
      while pos <= n and src:sub(pos, pos) ~= "\n" do pos = pos + 1 end
    elseif c == "|" then
      flush()
      if src:sub(pos + 1, pos + 1) == "|" then
        tokens[#tokens + 1] = { type = "or" }; pos = pos + 2
      else
        tokens[#tokens + 1] = { type = "pipe" }; pos = pos + 1
      end
    elseif c == "&" then
      if src:sub(pos + 1, pos + 1) == "&" then
        flush()
        tokens[#tokens + 1] = { type = "and" }; pos = pos + 2
      else
        return nil, "background jobs are not supported"
      end
    elseif c == ";" then
      flush()
      tokens[#tokens + 1] = { type = "semi" }; pos = pos + 1
    elseif c == ">" then
      flush()
      if src:sub(pos + 1, pos + 1) == ">" then
        tokens[#tokens + 1] = { type = "redir", op = ">>" }; pos = pos + 2
      else
        tokens[#tokens + 1] = { type = "redir", op = ">" }; pos = pos + 1
      end
    elseif c == "<" then
      flush()
      tokens[#tokens + 1] = { type = "redir", op = "<" }; pos = pos + 1
    elseif c == "2" and src:sub(pos + 1, pos + 1) == ">" and not word then
      flush()
      tokens[#tokens + 1] = { type = "redir", op = "2>" }; pos = pos + 2
    elseif c == "'" then
      local close = src:find("'", pos + 1, true)
      if not close then return nil, "unterminated single quote" end
      lit(src:sub(pos + 1, close - 1)); pos = close + 1
    elseif c == '"' then
      pos = pos + 1
      while pos <= n and src:sub(pos, pos) ~= '"' do
        local ch = src:sub(pos, pos)
        if ch == "\\" then
          local nxt = src:sub(pos + 1, pos + 1)
          if nxt == "" then return nil, "trailing backslash" end
          lit(nxt); pos = pos + 2
        elseif ch == "$" then
          local name, len = parse_var(src, pos + 1)
          if not name then return nil, "bad variable reference" end
          var(name); pos = pos + 1 + len
        else
          lit(ch); pos = pos + 1
        end
      end
      if pos > n then return nil, "unterminated double quote" end
      pos = pos + 1
    elseif c == "\\" then
      local nxt = src:sub(pos + 1, pos + 1)
      if nxt == "" then return nil, "trailing backslash" end
      lit(nxt); pos = pos + 2
    elseif c == "$" then
      local name, len = parse_var(src, pos + 1)
      if not name then
        lit("$"); pos = pos + 1
      else
        var(name); pos = pos + 1 + len
      end
    else
      lit(c); pos = pos + 1
    end
  end
  flush()
  return tokens
end

return M
