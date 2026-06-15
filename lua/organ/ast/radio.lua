local A = require("organ.ast.init")

local M = {}

-- Recursively visit every node, calling fn(node). Covers all child slots
-- that can hold AST nodes, including list items and table cells.
local function visit(n, fn)
  if type(n) ~= "table" then
    return
  end
  if n.kind then
    fn(n)
  end
  for _, slot in ipairs({ "children", "content", "inline", "title", "items", "description", "tag" }) do
    if type(n[slot]) == "table" then
      for _, c in ipairs(n[slot]) do
        visit(c, fn)
      end
    end
  end
  if type(n.rows) == "table" then
    for _, row in ipairs(n.rows) do
      if type(row.cells) == "table" then
        for _, cell in ipairs(row.cells) do
          if type(cell) == "table" then
            for _, c in ipairs(cell) do
              visit(c, fn)
            end
          end
        end
      end
    end
  end
end

-- Unique radio-target phrases in document order, deduped case-insensitively,
-- sorted by length descending (longest-match preference).
function M.collect_targets(ast)
  local seen, order = {}, {}
  visit(ast, function(n)
    if n.kind == "radio_target" and n.phrase and n.phrase:match("%S") then
      local key = n.phrase:lower()
      if not seen[key] then
        seen[key] = true
        order[#order + 1] = n.phrase
      end
    end
  end)
  table.sort(order, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return order
end

-- A Lua pattern matching the phrase case-insensitively (caller lowercases
-- the haystack): magic chars escaped, each whitespace run -> `%s+`.
local function phrase_pattern(phrase)
  local segs = {}
  for seg in phrase:lower():gmatch("%S+") do
    segs[#segs + 1] = (seg:gsub("(%W)", "%%%1"))
  end
  return table.concat(segs, "%s+")
end

local function is_alnum(c)
  return c ~= nil and c:match("[%a%d]") ~= nil
end

-- build_matcher(phrases) -> match(s) -> start, stop, phrase | nil.
-- `phrases` should be longest-first (as collect_targets returns).
function M.build_matcher(phrases)
  local pats = {}
  for _, p in ipairs(phrases) do
    pats[#pats + 1] = { phrase = p, pat = "^" .. phrase_pattern(p) }
  end
  return function(s)
    local lower = s:lower()
    for i = 1, #s do
      for _, e in ipairs(pats) do
        local st, sp = lower:find(e.pat, i)
        if st then
          local before = i > 1 and s:sub(i - 1, i - 1) or nil
          local after = sp < #s and s:sub(sp + 1, sp + 1) or nil
          if not is_alnum(before) and not is_alnum(after) then
            return i, sp, e.phrase
          end
        end
      end
    end
    return nil
  end
end

return M
