-- Footnote operations.  Compatible with Emacs `org-footnote-action`.
--
-- Reference forms recognised:
--   [fn:LABEL]              named reference (LABEL = word chars / _ / -)
--   [fn:LABEL: text]        inline-defined reference (definition embedded)
--   [fn::text]              anonymous inline footnote
--   [fn:N]                  numeric reference (LABEL = digits only)
--
-- Definition lines (top-level paragraph in their own right):
--   [fn:LABEL] body text…
--
-- Public API:
--   M.find_at_cursor()      → { kind = "ref"|"def", label, line, ... }
--   M.jump()                → ref → def (creating a stub if missing),
--                             def → ref of the same label.
--   M.insert(opts)          → insert a fresh `[fn:N]` reference at the
--                             cursor and a corresponding stub definition
--                             at the end of the buffer (or before the
--                             next headline, configurable).
--   M.renumber()            → re-sequence all numeric `[fn:N]` refs +
--                             defs into 1..K in order of first appearance.

local M = {}

local obuf = require("organ.buf")
-- Pattern building blocks

local DEF_LINE_PATTERN = "^%[fn:([%w_%-\128-\255]+)%]%s"

local function get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
end

-- Detection

-- Find the footnote reference (if any) that contains column `col` of
-- `text` (1-based byte column).  Returns { label, start_col, end_col }
-- or nil.
function M.ref_at(text, col)
  local i = 1
  while i <= #text do
    local s, e, _ = text:find("(%[fn:[%w_%-\128-\255]*[:%]])", i)
    if not s then
      return nil
    end
    -- Walk to matching `]`, allowing nested `[…]` modestly.
    local closing = e
    if text:sub(e, e) == "]" then
      -- Already at closing for `[fn:LABEL]`
    else
      -- `[fn:LABEL:` — find matching `]` (no nesting expected in practice).
      local p = text:find("]", e + 1, true)
      if p then
        closing = p
      else
        return nil
      end
    end
    if col >= s and col <= closing then
      local lbl = text:sub(s, closing):match("^%[fn:([%w_%-\128-\255]*)")
      return { label = lbl or "", start_col = s, end_col = closing }
    end
    i = closing + 1
  end
  return nil
end

-- Determine what's at the cursor.  Returns { kind = "ref"|"def", label,
-- line, start_col?, end_col? } or nil.
function M.find_at_cursor(bufnr)
  bufnr = bufnr or 0
  local cur_line = vim.fn.line(".")
  local cur_col = vim.fn.col(".")
  local txt = get_line(bufnr, cur_line)

  -- Definition? Line begins with `[fn:LABEL]`.
  local def_label = txt:match(DEF_LINE_PATTERN)
  if def_label then
    return { kind = "def", label = def_label, line = cur_line }
  end

  -- Reference at cursor column.
  local r = M.ref_at(txt, cur_col)
  if r and r.label and r.label ~= "" then
    return {
      kind = "ref",
      label = r.label,
      line = cur_line,
      start_col = r.start_col,
      end_col = r.end_col,
    }
  end
  return nil
end

-- Find first reference + first definition for a label.

local function find_first_def(bufnr, label)
  local total = vim.api.nvim_buf_line_count(bufnr)
  for i = 1, total do
    local txt = get_line(bufnr, i)
    if txt:match("^%[fn:" .. vim.pesc(label) .. "%]") then
      return i
    end
  end
  return nil
end

local function find_first_ref(bufnr, label)
  local total = vim.api.nvim_buf_line_count(bufnr)
  for i = 1, total do
    local txt = get_line(bufnr, i)
    -- `[fn:LABEL]` or `[fn:LABEL:…]` — but skip a definition line, which
    -- is a reference shape too.  Definition is at column 0; references
    -- are typically embedded.  We also skip if this line IS the
    -- definition for the same label.
    local at_col0 = txt:match("^%[fn:" .. vim.pesc(label) .. "[:%]]")
    if at_col0 and txt:match(DEF_LINE_PATTERN) == label then
      -- definition; skip
    else
      local s = txt:find("%[fn:" .. vim.pesc(label) .. "[:%]]")
      if s then
        return i, s
      end
    end
  end
  return nil
end

-- Public actions

function M.jump(bufnr)
  bufnr = bufnr or 0
  local ctx = M.find_at_cursor(bufnr)
  if not ctx then
    require("organ.notify").warn("not on a footnote")
    return false
  end
  if ctx.kind == "ref" then
    local def_line = find_first_def(bufnr, ctx.label)
    if not def_line then
      require("organ.notify").warn("no definition for [fn:" .. ctx.label .. "]")
      return false
    end
    vim.api.nvim_win_set_cursor(0, { def_line, 0 })
    return true
  end
  if ctx.kind == "def" then
    local ref_line, ref_col = find_first_ref(bufnr, ctx.label)
    if not ref_line then
      require("organ.notify").warn("no reference for [fn:" .. ctx.label .. "]")
      return false
    end
    vim.api.nvim_win_set_cursor(0, { ref_line, ref_col - 1 })
    return true
  end
  return false
end

-- Pick the next available numeric label (1..N+1).
local function next_numeric_label(bufnr)
  local seen = {}
  local total = vim.api.nvim_buf_line_count(bufnr)
  for i = 1, total do
    local txt = get_line(bufnr, i)
    for label in txt:gmatch("%[fn:(%d+)") do
      seen[tonumber(label)] = true
    end
  end
  local n = 1
  while seen[n] do
    n = n + 1
  end
  return n
end

-- Insert a numeric footnote reference at the cursor; ensure a stub
-- definition exists at the end of the buffer (or before the next
-- headline, per `opts.def_location`, default = "buffer-end").
function M.insert(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local cur_line, cur_col = cur[1], cur[2]

  local n = opts.label or next_numeric_label(bufnr)
  local ref_text = "[fn:" .. tostring(n) .. "]"

  -- Insert reference at cursor.
  local txt = get_line(bufnr, cur_line)
  local new_line = txt:sub(1, cur_col) .. ref_text .. txt:sub(cur_col + 1)
  obuf.set_lines(bufnr, cur_line - 1, cur_line, { new_line })

  -- Ensure definition stub exists.
  if not find_first_def(bufnr, tostring(n)) then
    local total = vim.api.nvim_buf_line_count(bufnr)
    local def_line
    if opts.def_location == "section-end" then
      -- Insert before the next `*+ ` headline after cur_line.
      def_line = total
      for i = cur_line + 1, total do
        if get_line(bufnr, i):match("^%*+ ") then
          def_line = i - 1
          break
        end
      end
    else
      def_line = total
    end
    local stub = ref_text .. " "
    -- Pad with a blank line if previous line isn't blank.
    local prev = get_line(bufnr, def_line)
    local insert = (prev == "") and { stub } or { "", stub }
    obuf.set_lines(bufnr, def_line, def_line, insert)
    -- Move to the stub for editing.
    local new_def_line = def_line + #insert
    vim.api.nvim_win_set_cursor(0, { new_def_line, #stub })
  end

  return n
end

-- Renumber numeric footnotes 1..K in order of first reference.
function M.renumber()
  local bufnr = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(bufnr)

  -- Pass 1: collect ordering.
  local order, seen = {}, {}
  for i = 1, total do
    local txt = get_line(bufnr, i)
    for label in txt:gmatch("%[fn:(%d+)[:%]]") do
      if not seen[label] then
        seen[label] = true
        order[#order + 1] = label
      end
    end
  end
  if #order == 0 then
    return 0
  end

  -- Build old → new map.
  local map = {}
  for i, label in ipairs(order) do
    map[label] = tostring(i)
  end

  -- Pass 2: rewrite every line.
  for i = 1, total do
    local txt = get_line(bufnr, i)
    local new = txt:gsub("(%[fn:)(%d+)([:%]])", function(p, label, suf)
      return p .. (map[label] or label) .. suf
    end)
    if new ~= txt then
      obuf.set_lines(bufnr, i - 1, i, { new })
    end
  end
  return #order
end

-- Inline → standalone normalisation.
--
-- Walks the buffer, finds every `[fn:LABEL:text]` and `[fn::text]` inline
-- footnote, replaces each with a bare `[fn:LABEL]` reference, and appends
-- the corresponding `[fn:LABEL] text` definition at the configured spot.
--
-- LABEL handling:
--   * Numeric labels are kept as-is.
--   * Named labels are kept as-is.
--   * Empty labels (`[fn::text]`) get the next available numeric label.
--
-- Returns the number of conversions performed.
function M.normalize_inline(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local definitions = {} -- list of "[fn:LABEL] body" lines to append.
  local n_converted = 0

  -- Collect labels already in use so anonymous inlines don't collide.
  local used = {}
  for _, ln in ipairs(lines) do
    for label in ln:gmatch("%[fn:(%d+)") do
      used[tonumber(label)] = true
    end
  end
  local function next_num()
    local n = 1
    while used[n] do
      n = n + 1
    end
    used[n] = true
    return n
  end

  for i, ln in ipairs(lines) do
    local out = {}
    local pos = 1
    while pos <= #ln do
      local s, e, label, body = ln:find("%[fn:([%w_%-\128-\255]*):([^%]]*)%]", pos)
      if not s then
        out[#out + 1] = ln:sub(pos)
        break
      end
      out[#out + 1] = ln:sub(pos, s - 1)
      if label == "" then
        label = tostring(next_num())
      end
      out[#out + 1] = "[fn:" .. label .. "]"
      definitions[#definitions + 1] = "[fn:" .. label .. "] " .. body
      n_converted = n_converted + 1
      pos = e + 1
    end
    if n_converted > 0 then
      lines[i] = table.concat(out)
    end
  end

  if n_converted == 0 then
    return 0
  end

  -- Find insertion point: end of buffer (default) or before the next headline
  -- (`opts.def_location == "section-end"`). For simplicity, default to buffer
  -- end and prepend a separating blank line.
  -- Append definitions.
  local function trim_trailing_blank()
    while #lines > 0 and lines[#lines] == "" do
      lines[#lines] = nil
    end
  end
  trim_trailing_blank()
  lines[#lines + 1] = ""
  for _, d in ipairs(definitions) do
    lines[#lines + 1] = d
  end
  obuf.set_lines(bufnr, 0, total, lines)
  return n_converted
end

-- Sort definitions by reference order.
--
-- Walks the buffer to determine the order of FIRST reference for each
-- footnote label. Then collects every `[fn:LABEL] body` definition line
-- (and its continuation lines, contiguous non-blank non-headline lines
-- following it), removes them in place, and re-inserts in reference
-- order at the same anchor (the line where the first definition lived).
-- Numeric labels also get re-sequenced 1..K via M.renumber semantics.
function M.sort()
  local bufnr = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(bufnr)

  -- Pass 1: collect first-reference order, ignoring lines that are
  -- themselves definitions (definitions also start with `[fn:LABEL]`).
  local order, seen = {}, {}
  for i = 1, total do
    local txt = get_line(bufnr, i)
    if not txt:match(DEF_LINE_PATTERN) then
      for label in txt:gmatch("%[fn:([%w_%-\128-\255]+)[:%]]") do
        if not seen[label] then
          seen[label] = true
          order[#order + 1] = label
        end
      end
    end
  end
  if #order == 0 then
    return 0
  end

  -- Pass 2: extract each definition + its continuation block. A
  -- "continuation" is any non-blank, non-headline, non-definition line
  -- immediately following the definition line.
  local defs = {} -- label → list-of-lines
  local first_def_idx -- 1-based line of the first definition encountered
  local to_remove = {} -- list of {start, end} (1-based, inclusive)

  local i = 1
  while i <= total do
    local txt = get_line(bufnr, i)
    local label = txt:match(DEF_LINE_PATTERN)
    if label then
      local block = { txt }
      local j = i + 1
      while j <= total do
        local l = get_line(bufnr, j)
        if l:match("^%s*$") or l:match("^%*+ ") or l:match(DEF_LINE_PATTERN) then
          break
        end
        block[#block + 1] = l
        j = j + 1
      end
      defs[label] = block
      to_remove[#to_remove + 1] = { i, j - 1 }
      first_def_idx = first_def_idx or i
      i = j
    else
      i = i + 1
    end
  end
  if not first_def_idx then
    return 0
  end

  -- Pass 3: remove the def blocks bottom-up so indices stay valid.
  for k = #to_remove, 1, -1 do
    local r = to_remove[k]
    obuf.set_lines(bufnr, r[1] - 1, r[2], {})
  end

  -- Re-build the ordered block in reference order; unknown-but-defined
  -- labels (referenced nowhere) come last in their original definition
  -- order to avoid silently dropping definitions.
  local emitted = {}
  local rebuilt = {}
  for _, label in ipairs(order) do
    if defs[label] then
      for _, l in ipairs(defs[label]) do
        rebuilt[#rebuilt + 1] = l
      end
      emitted[label] = true
    end
  end
  for label, block in pairs(defs) do
    if not emitted[label] then
      for _, l in ipairs(block) do
        rebuilt[#rebuilt + 1] = l
      end
    end
  end

  -- Account for the bottom-up removals shifting first_def_idx upwards.
  local removed_above = 0
  for _, r in ipairs(to_remove) do
    if r[1] < first_def_idx then
      removed_above = removed_above + (r[2] - r[1] + 1)
    end
  end
  local insert_at = first_def_idx - removed_above
  local new_total = vim.api.nvim_buf_line_count(bufnr)
  insert_at = math.min(insert_at, new_total + 1)

  obuf.set_lines(bufnr, insert_at - 1, insert_at - 1, rebuilt)
  -- Renumber numerics so they read 1..K in their NEW order.
  M.renumber()
  return #order
end

M.commands = {
  ["footnote jump"] = {
    fn = function()
      M.jump(0)
    end,
    desc = "Jump from a footnote reference to its definition (or vice versa)",
  },
  ["footnote insert"] = {
    fn = function()
      M.insert()
    end,
    desc = "Insert a new numeric footnote reference + stub definition",
  },
  ["footnote renumber"] = {
    fn = function()
      local n = M.renumber()
      require("organ.notify").info("renumbered " .. n .. " footnote(s)")
    end,
    desc = "Re-sequence numeric footnote labels in document order (1..K)",
  },
  ["footnote sort"] = {
    fn = function()
      local n = M.sort()
      require("organ.notify").notify(
        n > 0 and vim.log.levels.INFO or vim.log.levels.WARN,
        ("sorted %d footnote definition(s) by reference order"):format(n)
      )
    end,
    desc = "Reorder footnote definitions to match the order they're referenced",
  },
  ["footnote normalize"] = {
    fn = function()
      local n = M.normalize_inline()
      require("organ.notify").notify(
        n > 0 and vim.log.levels.INFO or vim.log.levels.WARN,
        ("normalised %d inline footnote(s)"):format(n)
      )
    end,
    desc = "Convert inline `[fn::body]` references into separate `[fn:N]` + `[fn:N] body`",
  },
}

return M
