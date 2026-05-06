-- Emacs `org-make-tags-matcher` query language → Lua predicate.
--
-- Subset implemented (covers the common cases):
--
--   Tags
--     +TAG    require tag           -TAG    forbid tag
--     TAG     require tag (default + when no prefix)
--
--   TODO state (after `/`)
--     /+NEXT  state must be NEXT
--     /-DONE  state must NOT be DONE
--
--   Title regex
--     {pattern}    title matches Lua pattern
--
--   Level
--     LEVEL=N      level == N           LEVEL>N      level > N
--     LEVEL<N      level < N            LEVEL>=N     LEVEL<=N
--
--   Property comparisons (string equality + numeric)
--     PROP="v"     equal              PROP<>"v"     not equal
--     PROP="v"|EFFORT>=30  combined within a clause
--
--   Disjunction
--     |            top-level OR between clauses
--
-- Example:
--   `+work-home/+NEXT|+@phone+EFFORT<60` → headlines tagged work
--   without home in state NEXT, OR tagged @phone with EFFORT < 60.

local M = {}

-- Tokenizer.

local function tokenize(s)
  local toks, i = {}, 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "|" then
      toks[#toks + 1] = { kind = "or" }
      i = i + 1
    elseif c == "/" then
      toks[#toks + 1] = { kind = "slash" }
      i = i + 1
    elseif c == "{" then
      local close = s:find("}", i + 1, true)
      if not close then
        error("match: unterminated {regex}")
      end
      toks[#toks + 1] = { kind = "regex", value = s:sub(i + 1, close - 1) }
      i = close + 1
    elseif c == "+" or c == "-" then
      toks[#toks + 1] = { kind = "sign", value = c }
      i = i + 1
    else
      -- Identifier-or-comparison. Walk while ident-char or comparison op.
      local j = i
      while j <= n do
        local cc = s:sub(j, j)
        if cc:match("[%w_@%%]") or cc == "<" or cc == ">" or cc == "=" or cc == "!" then
          j = j + 1
        elseif cc == '"' then
          -- consume the quoted string
          local close = s:find('"', j + 1, true)
          if not close then
            error('match: unterminated "value"')
          end
          j = close + 1
        else
          break
        end
      end
      toks[#toks + 1] = { kind = "atom", value = s:sub(i, j - 1) }
      i = j
    end
  end
  return toks
end

-- Parser.

-- An `atom` token may be a bare tag, a LEVEL=N clause, a PROP="v" clause,
-- a TODO=N comparison, or (after `/`) a TODO state name. Resolve here.
local CMP_OPS = {
  ["="] = true,
  ["!="] = true,
  ["<>"] = true,
  [">"] = true,
  ["<"] = true,
  [">="] = true,
  ["<="] = true,
}

local function strip_quotes(s)
  if s and s:sub(1, 1) == '"' and s:sub(-1) == '"' then
    return s:sub(2, -2)
  end
  return s
end

local function classify_atom(value)
  -- LEVEL is special.
  local op, rhs = value:match("^LEVEL([<>=!]+)(.*)$")
  if op then
    if op == "=" then
      op = "=="
    end
    return { kind = "level", op = op, value = tonumber(rhs) }
  end
  -- KEY OP RHS  (KEY = uppercase identifier).
  local key, op2, rhs2 = value:match("^([%u_][%w_]*)([<>=!]+)(.*)$")
  if key and op2 and rhs2 ~= nil then
    if op2 == "=" then
      op2 = "=="
    end
    if op2 == "<>" then
      op2 = "~="
    end
    if op2 == "!=" then
      op2 = "~="
    end
    rhs2 = strip_quotes(rhs2)
    if key == "TODO" then
      return { kind = "todo_eq", op = op2, value = rhs2 }
    end
    return { kind = "property", op = op2, key = key, value = rhs2 }
  end
  -- Bare tag.
  return { kind = "tag", value = value }
end

-- Parse one CLAUSE (tags + properties + level), optionally followed by /TODO.
-- Returns { tag_terms = {{op, value}, ...}, prop_terms = {...},
--           level_terms = {...}, todo_terms = {...}, regex = "..."? }.
local function parse_clause(toks, i)
  local clause = {
    tag_terms = {},
    prop_terms = {},
    level_terms = {},
    todo_terms = {},
    regex = nil,
  }
  local sign = "+" -- default require
  local in_todo_section = false

  while i <= #toks do
    local t = toks[i]
    if t.kind == "or" then
      break
    end
    if t.kind == "slash" then
      in_todo_section = true
      sign = "+"
      i = i + 1
    elseif t.kind == "sign" then
      sign = t.value
      i = i + 1
    elseif t.kind == "regex" then
      clause.regex = t.value
      i = i + 1
    elseif t.kind == "atom" then
      if in_todo_section then
        clause.todo_terms[#clause.todo_terms + 1] = { op = sign, value = t.value }
      else
        local cl = classify_atom(t.value)
        if cl.kind == "tag" then
          clause.tag_terms[#clause.tag_terms + 1] = { op = sign, value = cl.value }
        elseif cl.kind == "level" then
          clause.level_terms[#clause.level_terms + 1] = cl
        elseif cl.kind == "property" then
          clause.prop_terms[#clause.prop_terms + 1] = cl
        elseif cl.kind == "todo_eq" then
          clause.todo_terms[#clause.todo_terms + 1] = {
            op = (cl.op == "==" and "+" or "-"),
            value = cl.value,
          }
        end
      end
      sign = "+"
      i = i + 1
    else
      error("match: unexpected token " .. tostring(t.kind))
    end
  end
  return clause, i
end

function M.parse(query)
  if not query or query == "" then
    error("match: empty query")
  end
  local toks = tokenize(query)
  local clauses = {}
  local i = 1
  while i <= #toks do
    local clause
    clause, i = parse_clause(toks, i)
    clauses[#clauses + 1] = clause
    if toks[i] and toks[i].kind == "or" then
      i = i + 1
    end
  end
  return clauses
end

-- Evaluator. headline = { todo_state, tags = {...}, level, title, properties }

-- Resolve config.tags.groups: a parent tag matches when ANY member tag is
-- present on the headline (mirrors Emacs `:startgrouptag`/`:grouptags`/
-- `:endgrouptag` semantics). Returns a function(tag_name)->{matching_set...}
-- so each query expands `+gtd` into "any of @work, @home, @phone".
local function _tag_group_index()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return (organ.config.tags or {}).groups or {}
end

local function _tag_in_set(name, headline_tags, groups)
  for _, ht in ipairs(headline_tags or {}) do
    if ht == name then
      return true
    end
  end
  local members = groups[name]
  if members then
    for _, m in ipairs(members) do
      for _, ht in ipairs(headline_tags or {}) do
        if ht == m then
          return true
        end
      end
    end
  end
  return false
end

local function clause_matches(clause, h)
  local groups = _tag_group_index()
  for _, t in ipairs(clause.tag_terms) do
    local has = _tag_in_set(t.value, h.tags or {}, groups)
    if t.op == "+" and not has then
      return false
    end
    if t.op == "-" and has then
      return false
    end
  end
  for _, t in ipairs(clause.todo_terms) do
    local eq = (h.todo_state == t.value)
    if t.op == "+" and not eq then
      return false
    end
    if t.op == "-" and eq then
      return false
    end
  end
  for _, t in ipairs(clause.level_terms) do
    local lvl = h.level or 0
    local rhs = t.value or 0
    local op = t.op
    if op == "==" then
      if not (lvl == rhs) then
        return false
      end
    elseif op == "~=" then
      if not (lvl ~= rhs) then
        return false
      end
    elseif op == ">" then
      if not (lvl > rhs) then
        return false
      end
    elseif op == "<" then
      if not (lvl < rhs) then
        return false
      end
    elseif op == ">=" then
      if not (lvl >= rhs) then
        return false
      end
    elseif op == "<=" then
      if not (lvl <= rhs) then
        return false
      end
    end
  end
  for _, t in ipairs(clause.prop_terms) do
    local raw = (h.properties or {})[t.key]
    local rhs = t.value
    local rhs_n, raw_n = tonumber(rhs), tonumber(raw)
    local op = t.op
    if op == "==" then
      if not (raw == rhs) then
        return false
      end
    elseif op == "~=" then
      if not (raw ~= rhs) then
        return false
      end
    elseif op == ">" or op == "<" or op == ">=" or op == "<=" then
      if raw_n == nil or rhs_n == nil then
        return false
      end
      if op == ">" and not (raw_n > rhs_n) then
        return false
      end
      if op == "<" and not (raw_n < rhs_n) then
        return false
      end
      if op == ">=" and not (raw_n >= rhs_n) then
        return false
      end
      if op == "<=" and not (raw_n <= rhs_n) then
        return false
      end
    end
  end
  if clause.regex then
    local title = h.title or ""
    local ok, hit = pcall(string.match, title, clause.regex)
    if not (ok and hit) then
      return false
    end
  end
  return true
end

-- Build a predicate function compatible with sparse.apply.
function M.predicate(query)
  local clauses = M.parse(query)
  return function(h)
    for _, c in ipairs(clauses) do
      if clause_matches(c, h) then
        return true
      end
    end
    return false
  end
end

M._tokenize = tokenize
M._parse_clause = parse_clause
M._classify_atom = classify_atom
M._clause_matches = clause_matches

return M
