-- /sys/lib/sh/parser.lua — shell grammar parser.
--
-- AST shape:
--   list      = { items = { {pipeline, op="end"|"semi"|"and"|"or"}, ... } }
--   pipeline  = { commands = { command, ... } }
--   command   = { words = {parts, ...}, redirects = {redirect, ...} }
--   redirect  = { op = ">"|">>"|"<"|"2>", target = parts }
--
-- The op on each item is the SEPARATOR after that pipeline; "end" marks the
-- last item.

local M = {}

local function next_tok(state)
  local t = state.tokens[state.pos]; state.pos = state.pos + 1; return t
end
local function peek(state) return state.tokens[state.pos] end

local function parse_command(state)
  local cmd = { words = {}, redirects = {} }
  while true do
    local t = peek(state)
    if not t then break end
    if t.type == "word" then
      next_tok(state)
      cmd.words[#cmd.words + 1] = t.parts
    elseif t.type == "redir" then
      next_tok(state)
      local target = next_tok(state)
      if not target or target.type ~= "word" then
        return nil, "redirect '" .. t.op .. "' is missing its target"
      end
      cmd.redirects[#cmd.redirects + 1] = { op = t.op, target = target.parts }
    else
      break
    end
  end
  if #cmd.words == 0 and #cmd.redirects == 0 then
    return nil, "empty command"
  end
  return cmd
end

local function parse_pipeline(state)
  local commands = {}
  local first, err = parse_command(state)
  if not first then return nil, err end
  commands[#commands + 1] = first
  while peek(state) and peek(state).type == "pipe" do
    next_tok(state)
    local c, e = parse_command(state)
    if not c then return nil, e end
    commands[#commands + 1] = c
  end
  return { commands = commands }
end

function M.parse(tokens)
  local state = { tokens = tokens, pos = 1 }
  local items = {}
  while peek(state) do
    local p, err = parse_pipeline(state)
    if not p then return nil, err end
    local op = "end"
    local sep = peek(state)
    if sep and sep.type == "and" then op = "and"; next_tok(state)
    elseif sep and sep.type == "or"  then op = "or";  next_tok(state)
    elseif sep and sep.type == "semi" then op = "semi"; next_tok(state) end
    items[#items + 1] = { pipeline = p, op = op }
  end
  return { items = items }
end

return M
