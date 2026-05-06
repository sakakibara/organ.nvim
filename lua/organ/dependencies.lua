-- TODO dependencies: ORDERED, NOBLOCKING, parent-blocked-by-children.
--
-- Three guards block a TODO state transition until prerequisites are
-- satisfied. They mirror Emacs's `org-enforce-todo-dependencies` (and
-- friends) behaviour.
--
--   1. Parent blocked by children
--      A headline with at least one descendant in an active TODO state
--      cannot transition to DONE. Mirrors
--      `org-enforce-todo-dependencies = t`.
--
--   2. ORDERED siblings
--      A headline with a parent carrying `:ORDERED: t` cannot
--      transition to DONE while a previous sibling is still in an
--      active TODO state. Mirrors `org-enforce-todo-dependencies` plus
--      `:ORDERED: t`.
--
--   3. Checkbox dependencies
--      A headline cannot transition to DONE while any `- [ ]` checkbox
--      in its body is unchecked. Mirrors
--      `org-enforce-todo-checkbox-dependencies = t`.
--
-- A child with `:NOBLOCKING: t` is exempt from #1 — it does not block
-- its parent. (Org-mode reads NOBLOCKING the same way.) The checks all
-- run synchronously, before the buffer mutation in todo._apply, and
-- return a human-readable error string when blocked.

local M = {}

-- Sequence helpers (mirrors todo.lua locals; deliberately duplicated to
-- keep dependencies.lua loadable without pulling in todo.lua's mutation
-- side-effects).

-- Split a sequence-or-sequences value into flat actives/dones lists.
-- Accepts both shapes: flat `{"TODO", "|", "DONE"}` (single sequence)
-- and `{{"TODO", "|", "DONE"}, {"BUG", "|", "FIXED"}}` (multi-sequence
-- per Emacs `org-todo-keywords`).  Across multiple sub-sequences,
-- actives/dones are unioned.
local function split_seq(sequence_or_sequences)
  local actives, dones = {}, {}
  if type(sequence_or_sequences) ~= "table" then
    return actives, dones
  end
  local sequences
  if type(sequence_or_sequences[1]) == "table" then
    sequences = sequence_or_sequences
  else
    sequences = { sequence_or_sequences }
  end
  for _, seq in ipairs(sequences) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif in_done then
        dones[#dones + 1] = k
      else
        actives[#actives + 1] = k
      end
    end
  end
  return actives, dones
end

local function in_list(list, item)
  for _, v in ipairs(list) do
    if v == item then
      return true
    end
  end
  return false
end

local function is_active(state, sequence)
  local actives = split_seq(sequence)
  return state ~= nil and in_list(actives, state)
end

local function is_done(state, sequence)
  local _, dones = split_seq(sequence)
  return state ~= nil and in_list(dones, state)
end

-- Headline traversal

-- Stars + body of a headline line, with the leading TODO keyword (if
-- any) split off. Used to recover the state on every relevant headline
-- without round-tripping through todo.lua.
local function parse_headline(line, sequence)
  local stars, body = line:match("^(%*+)%s+(.*)$")
  if not stars then
    return nil
  end
  -- Drop priority cookie / tags before keyword detection — keyword is
  -- always the first token.
  local first = body:match("^(%S+)")
  local actives, dones = split_seq(sequence)
  if first and (in_list(actives, first) or in_list(dones, first)) then
    return #stars, first
  end
  return #stars, nil
end

-- Find the parent headline (1-based line index) of `hl_line`, defined
-- as the nearest preceding headline with `level` strictly less.
function M.parent_of(lines, hl_line)
  local stars = lines[hl_line]:match("^(%*+)%s")
  if not stars then
    return nil
  end
  local lvl = #stars
  for i = hl_line - 1, 1, -1 do
    local s = lines[i]:match("^(%*+)%s")
    if s and #s < lvl then
      return i
    end
  end
  return nil
end

-- Direct children of the headline at `hl_line`: lines whose level is
-- exactly `level + 1`, stopping at the next sibling-or-shallower
-- headline. Returns a list of 1-based line indices.
function M.children_of(lines, hl_line)
  local stars = lines[hl_line]:match("^(%*+)%s")
  if not stars then
    return {}
  end
  local lvl = #stars
  local out = {}
  for i = hl_line + 1, #lines do
    local s = lines[i]:match("^(%*+)%s")
    if s then
      if #s <= lvl then
        break
      end
      if #s == lvl + 1 then
        out[#out + 1] = i
      end
    end
  end
  return out
end

-- Every descendant headline (any depth) under `hl_line`. Stops at the
-- next sibling-or-shallower headline. Returns a list of 1-based line
-- indices.
function M.descendants_of(lines, hl_line)
  local stars = lines[hl_line]:match("^(%*+)%s")
  if not stars then
    return {}
  end
  local lvl = #stars
  local out = {}
  for i = hl_line + 1, #lines do
    local s = lines[i]:match("^(%*+)%s")
    if s then
      if #s <= lvl then
        break
      end
      out[#out + 1] = i
    end
  end
  return out
end

-- Previous siblings of `hl_line` under the same parent (i.e. headlines
-- at the same level reached without crossing a shallower headline).
-- Returned in document order. The result EXCLUDES `hl_line`.
function M.previous_siblings_of(lines, hl_line)
  local stars = lines[hl_line]:match("^(%*+)%s")
  if not stars then
    return {}
  end
  local lvl = #stars
  local out = {}
  for i = hl_line - 1, 1, -1 do
    local s = lines[i]:match("^(%*+)%s")
    if s then
      if #s < lvl then
        break
      end
      if #s == lvl then
        out[#out + 1] = i
      end
    end
  end
  -- Reverse to document order.
  local reversed = {}
  for i = #out, 1, -1 do
    reversed[#reversed + 1] = out[i]
  end
  return reversed
end

-- Property lookup (lightweight — does not pull in property.lua to avoid
-- mutation-side-effect coupling). Reads the PROPERTIES drawer beneath
-- a headline if present and returns the value of `key` (case-insens),
-- or nil.

local function planning_end(lines, hl_line)
  local i = hl_line + 1
  while i <= #lines do
    local l = lines[i]
    if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
      i = i + 1
    else
      break
    end
  end
  return i
end

function M.property_of(lines, hl_line, key)
  local key_l = key:upper()
  local i = planning_end(lines, hl_line)
  if i > #lines then
    return nil
  end
  if not (lines[i] or ""):match("^%s*:PROPERTIES:%s*$") then
    return nil
  end
  i = i + 1
  while i <= #lines do
    local l = lines[i]
    if l:match("^%s*:END:%s*$") then
      return nil
    end
    local k, v = l:match("^%s*:([%w%-_]+):%s*(.-)%s*$")
    if k and k:upper() == key_l then
      return v
    end
    i = i + 1
  end
  return nil
end

-- Body-checkbox scanning

-- Returns true when at least one `- [ ]` checkbox in the body of
-- `hl_line` (between this headline and the next one of equal-or-shallower
-- level) is unchecked. Excludes `[X]` / `[x]` / `[-]` (partial).
function M.has_unchecked_box(lines, hl_line)
  local stars = lines[hl_line]:match("^(%*+)%s")
  if not stars then
    return false
  end
  local lvl = #stars
  for i = hl_line + 1, #lines do
    local s = lines[i]:match("^(%*+)%s")
    if s and #s <= lvl then
      break
    end
    -- `- [ ]` / `* [ ]` / `+ [ ]` / `1. [ ]` etc.
    if (lines[i] or ""):match("^%s*[%-%+%*]%s+%[ %]") then
      return true
    end
    if (lines[i] or ""):match("^%s*%d+[.)]%s+%[ %]") then
      return true
    end
  end
  return false
end

-- Dependency check entry point

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok then
    return {}
  end
  return (organ.config and organ.config.todo) or {}
end

-- Probe the buffer for blocking conditions on transitioning the
-- headline at `hl_line` to `new_state`. Returns nil when the change is
-- allowed, or an error string when blocked.
--
--   sequence: TODO keyword sequence (incl. `|` separator).
function M.check(bufnr, hl_line, new_state, sequence)
  local cfg = get_config()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M._check_lines(lines, hl_line, new_state, sequence, cfg)
end

-- Pure variant for tests: takes the buffer lines directly so we can
-- exercise the logic without mounting a real buffer.
function M._check_lines(lines, hl_line, new_state, sequence, cfg)
  cfg = cfg or {}
  -- Only transitions to a DONE state are subject to dependency checks.
  -- Active / cleared transitions always pass (they don't represent
  -- "completion", so blocking them would just frustrate users).
  if not is_done(new_state, sequence) then
    return nil
  end

  -- Guard 1: any descendant in an active state blocks the transition,
  -- unless the descendant has :NOBLOCKING: t.
  if cfg.enforce_dependencies ~= false then
    for _, idx in ipairs(M.descendants_of(lines, hl_line)) do
      local _, state = parse_headline(lines[idx], sequence)
      if
        is_active(state, sequence)
        and (M.property_of(lines, idx, "NOBLOCKING") or ""):lower() ~= "t"
      then
        return string.format("TODO blocked: descendant on line %d (%s) is still active", idx, state)
      end
    end
  end

  -- Guard 2: parent ORDERED → previous siblings must be DONE first.
  if cfg.enforce_dependencies ~= false then
    local parent = M.parent_of(lines, hl_line)
    if parent and (M.property_of(lines, parent, "ORDERED") or ""):lower() == "t" then
      for _, sib in ipairs(M.previous_siblings_of(lines, hl_line)) do
        local _, state = parse_headline(lines[sib], sequence)
        if not is_done(state, sequence) then
          return string.format(
            "TODO blocked: ORDERED parent — previous sibling on line %d is not DONE",
            sib
          )
        end
      end
    end
  end

  -- Guard 3: checkbox dependencies (only when explicitly enabled —
  -- defaults off because not every buffer uses checkbox semantics).
  if cfg.enforce_checkbox_dependencies and M.has_unchecked_box(lines, hl_line) then
    return "TODO blocked: unchecked checkbox in body"
  end

  return nil
end

M._is_done = is_done
M._is_active = is_active
M._split_seq = split_seq

M.commands = {
  toggle_ordered = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local prop = require("organ.property")
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local hl = line
      while hl >= 1 and not (lines[hl] or ""):match("^%*+%s") do
        hl = hl - 1
      end
      if hl < 1 then
        require("organ.notify").warn("toggle_ordered: no headline at or above cursor")
        return
      end
      local current = M.property_of(lines, hl, "ORDERED")
      if (current or ""):lower() == "t" then
        prop.delete(bufnr, hl, "ORDERED")
        require("organ.notify").info("organ: ORDERED removed")
      else
        prop.set(bufnr, hl, "ORDERED", "t")
        require("organ.notify").info("organ: ORDERED set — children must complete in order")
      end
    end,
    desc = "Toggle :ORDERED: on the headline (children must complete in order)",
  },
}

return M
