-- Statistics cookies: `[N/M]` and `[XX%]` markers that auto-track progress.
--
-- Two contexts:
--   1. Headline cookie: counts direct child headlines whose TODO state is in
--      the configured "done" set vs total child headlines that have any TODO
--      state. (Headlines with no TODO state are skipped — matches Emacs.)
--   2. List-item cookie: counts checked checkboxes among descendant list
--      items vs total checkboxed items.
--
-- Either form may use `[N/M]` (numerator/denominator) or `[XX%]` (rounded
-- percent). Both forms cohabit: `Foo [1/3] [33%]` is valid and both update.

local M = {}

-- Sequence helpers (pulled from organ.todo so we don't depend on its module
-- loading inside every cookie update).

-- Returns the user's todo config (single or multi-sequence shape).
-- All consumers below pass through todo._normalise_sequences so both
-- shapes work and annotations are stripped.
local function todo_keywords()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config or not organ.config.todo then
    return { "TODO", "|", "DONE" }
  end
  return organ.config.todo.sequences or organ.config.todo.sequence or { "TODO", "|", "DONE" }
end

local function done_set(input)
  local set = {}
  for _, seq in ipairs(require("organ.todo")._normalise_sequences(input)) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif in_done then
        set[k] = true
      end
    end
  end
  return set
end

local function active_set(input)
  local set = {}
  for _, seq in ipairs(require("organ.todo")._normalise_sequences(input)) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif not in_done then
        set[k] = true
      end
    end
  end
  return set
end

local function any_todo_kw(input)
  local set = {}
  for _, k in ipairs(require("organ.todo").all_keywords(input)) do
    set[k] = true
  end
  return set
end

-- Cookie patterns.

-- Match `[N/M]` and `[XX%]` cookies. Returns (kind, start_byte, end_byte)
-- iterator; kind is "fraction" or "percent".
local function cookies_in(line)
  local out = {}
  local pos = 1
  while true do
    local s, e, n, d = line:find("(%[(%d*)/(%d*)%])", pos)
    if s then
      out[#out + 1] = { kind = "fraction", s = s, e = e }
      pos = e + 1
    else
      break
    end
  end
  pos = 1
  while true do
    local s, e, p = line:find("(%[(%d*)%%%])", pos)
    if s then
      out[#out + 1] = { kind = "percent", s = s, e = e }
      pos = e + 1
    else
      break
    end
  end
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

-- Headline cookie counts.

-- Walk descendants of headline at hl_line. For each direct child headline
-- (level == parent_level + 1) that carries a TODO state, count toward
-- denominator; if state is in done_set, count toward numerator.
--
-- `recursive = true` walks deeper than direct children (matches Emacs
-- `org-checkbox-hierarchical-statistics` for headlines).
local function count_children(lines, hl_line, opts)
  opts = opts or {}
  local seq = todo_keywords()
  local done = done_set(seq)
  local any = any_todo_kw(seq)

  local parent_stars = (lines[hl_line] or ""):match("^(%*+)%s") or ""
  local parent_level = #parent_stars
  if parent_level == 0 then
    return 0, 0
  end

  local total, done_n = 0, 0
  for i = hl_line + 1, #lines do
    local stars = (lines[i] or ""):match("^(%*+)%s")
    if stars then
      local lvl = #stars
      if lvl <= parent_level then
        break
      end
      local is_direct_child = (lvl == parent_level + 1)
      if opts.recursive or is_direct_child then
        local kw = (lines[i] or ""):match("^%*+%s+([A-Z][A-Z_]+)%s")
        if kw and any[kw] then
          total = total + 1
          if done[kw] then
            done_n = done_n + 1
          end
        end
      end
    end
  end
  return done_n, total
end

-- List-item cookie counts.

-- Returns the list-block range [s, e] (1-based) covering the line at `lnum`.
-- A list block is a contiguous run of list items at indent ≥ first item's
-- indent, optionally interrupted by continuation lines.
local function list_block(lines, lnum)
  local function is_item(s)
    return (s or ""):match("^%s*[%-%+%*]%s") ~= nil or (s or ""):match("^%s*%d+[%.%)]%s") ~= nil
  end
  if not is_item(lines[lnum]) then
    return nil, nil
  end
  local indent = (lines[lnum] or ""):match("^(%s*)") or ""
  local center_indent = #indent
  local s, e = lnum, lnum
  for i = lnum - 1, 1, -1 do
    if is_item(lines[i]) then
      local ind = #((lines[i] or ""):match("^(%s*)") or "")
      if ind <= center_indent then
        s = i
      end
      if ind < center_indent then
        break
      end
    elseif (lines[i] or ""):match("^%s*$") then
      break
    else
      break
    end
  end
  for i = lnum + 1, #lines do
    if is_item(lines[i]) then
      local ind = #((lines[i] or ""):match("^(%s*)") or "")
      if ind >= center_indent then
        e = i
      else
        break
      end
    elseif (lines[i] or ""):match("^%s*$") then
      break
    else
      break
    end
  end
  return s, e
end

local function count_checkboxes(lines, lnum)
  -- Owner of the cookie can be a list item; we count checkboxed items at
  -- the same indent as that owner's children (one level deeper) when
  -- `recursive` is false; otherwise we count every checkboxed descendant
  -- in the contiguous list block. Default: hierarchical (Emacs default).
  local s, e = list_block(lines, lnum)
  if not s then
    return 0, 0
  end
  local owner_indent = #((lines[lnum] or ""):match("^(%s*)") or "")
  local total, checked = 0, 0
  for i = s, e do
    local ind = #((lines[i] or ""):match("^(%s*)") or "")
    if i ~= lnum and ind > owner_indent then
      local mark = (lines[i] or ""):match("^%s*[%-%+%*]%s+%[([ Xx%-])%]")
        or (lines[i] or ""):match("^%s*%d+[%.%)]%s+%[([ Xx%-])%]")
      if mark then
        total = total + 1
        if mark == "X" or mark == "x" then
          checked = checked + 1
        end
      end
    end
  end
  return checked, total
end

-- Cookie rewriting.

local function format_cookie(kind, num, den)
  if kind == "fraction" then
    return string.format("[%d/%d]", num, den)
  elseif kind == "percent" then
    if den == 0 then
      return "[0%]"
    end
    return string.format("[%d%%]", math.floor((num * 100 / den) + 0.5))
  end
  return ""
end

-- Update every cookie on `line` against (num, den). Returns the new line.
local function rewrite_cookies(line, num, den)
  local out = line
  -- fraction first then percent — order independent because patterns differ.
  out = out:gsub("%[(%d*)/(%d*)%]", function()
    return format_cookie("fraction", num, den)
  end)
  out = out:gsub("%[(%d*)%%%]", function()
    return format_cookie("percent", num, den)
  end)
  return out
end

-- Public API.

-- Update cookies for a single line (1-based) in bufnr. Picks counting
-- strategy based on whether the line is a headline or a list item.
function M.update_line(bufnr, lnum, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[lnum] or ""
  local cks = cookies_in(line)
  if #cks == 0 then
    return false
  end

  local num, den
  if line:match("^%*+%s") then
    num, den = count_children(lines, lnum, opts)
  else
    num, den = count_checkboxes(lines, lnum)
  end
  local new = rewrite_cookies(line, num, den)
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
    return true
  end
  return false
end

-- Update every cookie line in the buffer. Returns the number of lines
-- that changed.
function M.update_buffer(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n_changed = 0
  for i, ln in ipairs(lines) do
    if #cookies_in(ln) > 0 then
      if M.update_line(bufnr, i, opts) then
        n_changed = n_changed + 1
      end
    end
  end
  return n_changed
end

-- Helper called from todo state changes / checkbox toggles. Walks every
-- ancestor headline of `lnum` and updates each that carries a cookie.
-- Cheap because most files have few cookies.
function M.update_ancestors(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local i = lnum
  while i >= 1 do
    local ln = lines[i] or ""
    if ln:match("^%*+%s") and #cookies_in(ln) > 0 then
      M.update_line(bufnr, i)
    end
    if ln:match("^%*+%s") then
      -- Climb to parent: find the previous headline with strictly fewer stars.
      local stars = #(ln:match("^(%*+)") or "")
      local parent
      for j = i - 1, 1, -1 do
        local pj = (lines[j] or ""):match("^(%*+)%s")
        if pj and #pj < stars then
          parent = j
          break
        end
      end
      if not parent then
        break
      end
      i = parent
    else
      i = i - 1
    end
  end
end

-- Exposed for tests.
M._cookies_in = cookies_in
M._count_children = count_children
M._count_checkboxes = count_checkboxes
M._format_cookie = format_cookie
M._rewrite_cookies = rewrite_cookies

M.commands = {
  update_statistics = {
    fn = function()
      local n = M.update_buffer(0)
      require("organ.notify").info(("updated %d cookie line(s)"):format(n))
    end,
    desc = "Recompute every [N/M] and [%] cookie in the current buffer",
  },
}

return M
