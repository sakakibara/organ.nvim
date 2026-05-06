-- Org tables — pipe-delimited (`| a |---+---| b |`). Generic parsing,
-- alignment, navigation, and structural operations live in tablature.nvim;
-- this module wires the org dialect to organ's command dispatch and adds
-- org-specific TBLFM (`#+TBLFM:`) formula evaluation on top.

local M = {}

local tab = require("tablature")

local ORG = { dialect = "org" }

local function is_alignment_row(row)
  if row.sep then
    return false
  end
  local has_marker = false
  for _, c in ipairs(row.cells) do
    if c == "" then -- ok
    elseif c == "<l>" or c == "<r>" or c == "<c>" then
      has_marker = true
    else
      return false
    end
  end
  return has_marker
end

-- Thin pass-through wrappers so organ's command layer can keep calling
-- M.realign / M.tab / etc. without depending on the tablature module
-- directly.

function M.realign(bufnr, line)
  return tab.realign(bufnr, line, ORG)
end

function M.tab(bufnr)
  return tab.tab(bufnr, ORG)
end

function M.shift_tab(bufnr)
  return tab.shift_tab(bufnr, ORG)
end

function M.insert_row_below(bufnr)
  return tab.insert_row_below(bufnr, nil, ORG)
end
function M.insert_row_above(bufnr)
  return tab.insert_row_above(bufnr, nil, ORG)
end
function M.delete_row(bufnr)
  return tab.delete_row(bufnr, nil, ORG)
end
function M.move_row_up(bufnr)
  return tab.move_row_up(bufnr, nil, ORG)
end
function M.move_row_down(bufnr)
  return tab.move_row_down(bufnr, nil, ORG)
end

function M.insert_column_right(bufnr)
  return tab.insert_column_right(bufnr, nil, ORG)
end
function M.insert_column_left(bufnr)
  return tab.insert_column_left(bufnr, nil, ORG)
end
function M.delete_column(bufnr)
  return tab.delete_column(bufnr, nil, ORG)
end
function M.move_column_left(bufnr)
  return tab.move_column_left(bufnr, nil, ORG)
end
function M.move_column_right(bufnr)
  return tab.move_column_right(bufnr, nil, ORG)
end

-- Org sort: the first data row is always a header even when no separator
-- exists; row 2 is also a header if it's a separator or an alignment row.
-- Tablature's generic sort only treats sep/block rows as fence posts, so
-- we re-implement the org heuristic here on top of ops.sort.
function M.sort_by_current_column(bufnr, direction)
  local lnum = vim.fn.line(".")
  local col = vim.fn.col(".") - 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local t = tab.parse(lines, lnum, ORG)
  if not t then
    return false
  end

  local cur_cell = M._cursor_to_cell(lines[lnum], col) or 1

  local header_count = 1
  if #t.rows >= 2 and (t.rows[2].sep or is_alignment_row(t.rows[2])) then
    header_count = 2
  end

  local headers, body = {}, {}
  for i, r in ipairs(t.rows) do
    if i <= header_count or r.sep then
      headers[#headers + 1] = { idx = i, row = r }
    else
      body[#body + 1] = r
    end
  end

  local sorted = tab.ops.sort(body, cur_cell, direction or "asc", "auto")

  local new_rows = {}
  for _, h in ipairs(headers) do
    new_rows[#new_rows + 1] = h.row
  end
  for _, r in ipairs(sorted) do
    new_rows[#new_rows + 1] = r
  end

  local new_lines = tab.align(new_rows, t.indent, ORG)
  vim.api.nvim_buf_set_lines(bufnr, t.start_line - 1, t.end_line, false, new_lines)
  return true
end

-- Pure-parser wrappers, retained for callers (e.g. element_cache, formula
-- evaluator below) that want the parsed structure directly.

function M._parse(buf_lines, line)
  return tab.parse(buf_lines, line, ORG)
end

function M._align(rows, indent)
  return tab.align(rows, indent, ORG)
end

function M._cursor_to_cell(line_text, col_0_based)
  -- Re-implemented locally because tablature's helper isn't a public API.
  -- A tablature internal-call would be preferable but this is one-screen.
  local positions = {}
  for i = 1, #line_text do
    if line_text:sub(i, i) == "|" then
      positions[#positions + 1] = i - 1
    end
  end
  if #positions < 2 then
    return nil
  end
  for k = 1, #positions - 1 do
    if col_0_based >= positions[k] and col_0_based < positions[k + 1] then
      return k
    end
  end
  return #positions - 1
end

-- Org-specific: TBLFM evaluation. is_alignment_row defined above.

function M.find_tblfm(bufnr, table_range)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local next_lnum = table_range.end_line + 1
  if next_lnum > total then
    return nil
  end
  -- Walk for the `formula` grammar node first (handles surrounding
  -- whitespace and casing without ad-hoc regex).  `formula_at`
  -- transparently falls back to regex when the parser isn't loaded.
  local body = require("organ.element").formula_at(bufnr, next_lnum - 1)
  if not body or body == "" then
    return nil
  end
  return { line = next_lnum, formula_text = body }
end

local function format_result(value)
  if value == nil then
    return "#ERROR"
  end
  if type(value) == "table" then
    return "#ERROR"
  end
  if value == math.floor(value) and math.abs(value) < 1e15 then
    return tostring(math.floor(value))
  end
  return string.format("%.2f", value)
end

function M.eval_formulas(bufnr)
  local lnum = vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local t = tab.parse(lines, lnum, ORG)
  if not t then
    require("organ.notify").warn("not in a table")
    return false
  end
  local tblfm = M.find_tblfm(bufnr, t)
  if not tblfm then
    require("organ.notify").warn("no #+TBLFM: line below this table")
    return false
  end
  local formula = require("organ.table.formula")
  local ok, formulas = pcall(formula.parse, tblfm.formula_text)
  if not ok then
    require("organ.notify").error("organ: TBLFM parse error: " .. tostring(formulas))
    return false
  end

  local has_sep = false
  for _, r in ipairs(t.rows) do
    if r.sep then
      has_sep = true
      break
    end
  end
  local header_count = 0
  if has_sep then
    header_count = 1
    if #t.rows >= 2 and (t.rows[2].sep or is_alignment_row(t.rows[2])) then
      header_count = 2
    end
  end

  for _, fm in ipairs(formulas) do
    if fm.kind == "col_formula" then
      for r = header_count + 1, #t.rows do
        if not t.rows[r].sep and not is_alignment_row(t.rows[r]) then
          local v = formula.eval(fm.expr, { rows = t.rows, current_row = r, current_col = fm.col })
          while #t.rows[r].cells < fm.col do
            t.rows[r].cells[#t.rows[r].cells + 1] = ""
          end
          t.rows[r].cells[fm.col] = format_result(v)
        end
      end
    elseif fm.kind == "cell_formula" then
      local r = t.rows[fm.row]
      if r and not r.sep then
        local v =
          formula.eval(fm.expr, { rows = t.rows, current_row = fm.row, current_col = fm.col })
        while #r.cells < fm.col do
          r.cells[#r.cells + 1] = ""
        end
        r.cells[fm.col] = format_result(v)
      end
    elseif fm.kind == "row_formula" then
      local r = t.rows[fm.row]
      if r and not r.sep then
        for c = 1, #r.cells do
          local v = formula.eval(fm.expr, { rows = t.rows, current_row = fm.row, current_col = c })
          r.cells[c] = format_result(v)
        end
      end
    end
  end

  local new_lines = tab.align(t.rows, t.indent, ORG)
  vim.api.nvim_buf_set_lines(bufnr, t.start_line - 1, t.end_line, false, new_lines)
  return true
end

local TABLE_MENU_OPS = {
  {
    label = "Insert row below",
    fn = function()
      M.insert_row_below(0)
    end,
  },
  {
    label = "Insert row above",
    fn = function()
      M.insert_row_above(0)
    end,
  },
  {
    label = "Delete row",
    fn = function()
      M.delete_row(0)
    end,
  },
  {
    label = "Move row up",
    fn = function()
      M.move_row_up(0)
    end,
  },
  {
    label = "Move row down",
    fn = function()
      M.move_row_down(0)
    end,
  },
  {
    label = "Insert column right",
    fn = function()
      M.insert_column_right(0)
    end,
  },
  {
    label = "Insert column left",
    fn = function()
      M.insert_column_left(0)
    end,
  },
  {
    label = "Delete column",
    fn = function()
      M.delete_column(0)
    end,
  },
  {
    label = "Move column left",
    fn = function()
      M.move_column_left(0)
    end,
  },
  {
    label = "Move column right",
    fn = function()
      M.move_column_right(0)
    end,
  },
  {
    label = "Sort by current column",
    fn = function()
      vim.ui.select({ "Ascending", "Descending" }, { prompt = "Sort direction" }, function(choice)
        if not choice then
          return
        end
        M.sort_by_current_column(0, choice == "Ascending" and "asc" or "desc")
      end)
    end,
  },
  {
    label = "Evaluate formulas",
    fn = function()
      M.eval_formulas(0)
    end,
  },
}

function M.open_menu()
  local labels = {}
  for _, op in ipairs(TABLE_MENU_OPS) do
    labels[#labels + 1] = op.label
  end
  vim.ui.select(labels, { prompt = "organ table:" }, function(choice, idx)
    if choice and TABLE_MENU_OPS[idx] then
      TABLE_MENU_OPS[idx].fn()
    end
  end)
end

M.commands = {
  ["table insert_row"] = {
    fn = function()
      M.insert_row_below(0)
    end,
    desc = "Insert row below",
  },
  ["table insert_row_above"] = {
    fn = function()
      M.insert_row_above(0)
    end,
    desc = "Insert row above",
  },
  ["table delete_row"] = {
    fn = function()
      M.delete_row(0)
    end,
    desc = "Delete current row",
  },
  ["table move_row_up"] = {
    fn = function()
      M.move_row_up(0)
    end,
    desc = "Move row up",
  },
  ["table move_row_down"] = {
    fn = function()
      M.move_row_down(0)
    end,
    desc = "Move row down",
  },
  ["table insert_column"] = {
    fn = function()
      M.insert_column_right(0)
    end,
    desc = "Insert column right",
  },
  ["table insert_column_left"] = {
    fn = function()
      M.insert_column_left(0)
    end,
    desc = "Insert column left",
  },
  ["table delete_column"] = {
    fn = function()
      M.delete_column(0)
    end,
    desc = "Delete current column",
  },
  ["table move_column_left"] = {
    fn = function()
      M.move_column_left(0)
    end,
    desc = "Move column left",
  },
  ["table move_column_right"] = {
    fn = function()
      M.move_column_right(0)
    end,
    desc = "Move column right",
  },
  ["table sort"] = {
    fn = function()
      vim.ui.select({ "Ascending", "Descending" }, { prompt = "Sort direction" }, function(choice)
        if not choice then
          return
        end
        M.sort_by_current_column(0, choice == "Ascending" and "asc" or "desc")
      end)
    end,
    desc = "Sort table by current column",
  },
  ["table eval_formulas"] = {
    fn = function()
      M.eval_formulas(0)
    end,
    desc = "Evaluate #+TBLFM: formulas for the table at cursor",
  },
}

return M
