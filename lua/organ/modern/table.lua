-- Pretty pipe-table rendering: replaces ASCII pipe / dash / plus
-- chars with Unicode box-drawing equivalents and (optionally) draws
-- top + bottom virtual borders.  Org-specific extras: alignment-row
-- markers (`<l>` / `<r>` / `<c>` rendered as arrows) and an insert-
-- mode pause that stops refreshing while the user is mid-keystroke
-- (avoids the conceal-flicker that makes typing inside cells
-- distracting).

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_table")

local PRESETS = {
  light = {
    vert = "│",
    horiz = "─",
    cross = "┼",
    teel = "├",
    teer = "┤",
    topl = "┌",
    topm = "┬",
    topr = "┐",
    botl = "└",
    botm = "┴",
    botr = "┘",
  },
  round = {
    vert = "│",
    horiz = "─",
    cross = "┼",
    teel = "├",
    teer = "┤",
    topl = "╭",
    topm = "┬",
    topr = "╮",
    botl = "╰",
    botm = "┴",
    botr = "╯",
  },
  heavy = {
    vert = "┃",
    horiz = "━",
    cross = "╋",
    teel = "┣",
    teer = "┫",
    topl = "┏",
    topm = "┳",
    topr = "┓",
    botl = "┗",
    botm = "┻",
    botr = "┛",
  },
  double = {
    vert = "║",
    horiz = "═",
    cross = "╬",
    teel = "╠",
    teer = "╣",
    topl = "╔",
    topm = "╦",
    topr = "╗",
    botl = "╚",
    botm = "╩",
    botr = "╝",
  },
}

local function preset_for(cfg)
  return PRESETS[cfg.preset] or PRESETS.light
end

local function is_table_line(line)
  return line:match("^%s*|") ~= nil
end

-- A rule row contains only `[-+|]` chars (plus surrounding space).
local function is_rule_row(line)
  return is_table_line(line) and line:match("^%s*[|+%-]+%s*$") ~= nil
end

-- An alignment row contains `<l>`/`<r>`/`<c>` cells and nothing
-- else.  Org-specific (Emacs `org-table-align`).  Each cell is
-- 3 chars between pipes.
local function is_alignment_row(line)
  if not is_table_line(line) or is_rule_row(line) then
    return false
  end
  for cell in line:gmatch("|([^|]*)") do
    local trimmed = cell:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed ~= "<l>" and trimmed ~= "<r>" and trimmed ~= "<c>" then
      return false
    end
  end
  return true
end

local function conceal(bufnr, row, col_0, repl, hl)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, col_0, {
    end_col = col_0 + 1,
    conceal = repl,
    hl_group = hl,
  })
end

local function pipe_positions(line)
  local out = {}
  for i = 1, #line do
    if line:sub(i, i) == "|" then
      out[#out + 1] = i
    end
  end
  return out
end

-- Build the top or bottom virtual border line for a table whose
-- row uses pipe positions `pipes` (1-based byte indices).  Lead-in
-- whitespace is preserved so the border lines up under indented
-- tables.
local function build_border_line(line, pipes, p, kind)
  local indent = line:match("^(%s*)") or ""
  local out = { indent }
  local first_pipe = pipes[1]
  local last_pipe = pipes[#pipes]
  for i = first_pipe, last_pipe do
    if i == first_pipe then
      out[#out + 1] = (kind == "top") and p.topl or p.botl
    elseif i == last_pipe then
      out[#out + 1] = (kind == "top") and p.topr or p.botr
    else
      local is_pipe = false
      for _, pp in ipairs(pipes) do
        if pp == i then
          is_pipe = true
          break
        end
      end
      if is_pipe then
        out[#out + 1] = (kind == "top") and p.topm or p.botm
      else
        out[#out + 1] = p.horiz
      end
    end
  end
  return table.concat(out)
end

-- Conceal-replace ASCII chars on a single table row (data, rule,
-- or alignment).  `kind` selects the rule-row corner set or the
-- straight-vertical for data rows.
local function decorate_row(bufnr, row, line, p, edges)
  if is_rule_row(line) then
    local pipes = pipe_positions(line)
    for idx, col in ipairs(pipes) do
      local repl
      if edges and idx == 1 then
        repl = p.teel
      elseif edges and idx == #pipes then
        repl = p.teer
      else
        repl = p.cross
      end
      conceal(bufnr, row, col - 1, repl, "@org.table.delimiter")
    end
    for i = 1, #line do
      local c = line:sub(i, i)
      if c == "+" then
        conceal(bufnr, row, i - 1, p.cross, "@org.table.delimiter")
      elseif c == "-" then
        conceal(bufnr, row, i - 1, p.horiz, "@org.table.delimiter")
      end
    end
  elseif is_alignment_row(line) then
    -- Conceal `<l>`/`<r>`/`<c>` markers with arrows.  Each marker
    -- is 3 bytes; collapse to a single visual char.
    for pos, marker in line:gmatch("()(<[lrc]>)") do
      local arrow = (marker == "<l>") and "←" or (marker == "<r>") and "→" or "·"
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, pos - 1, {
        end_col = pos - 1 + 3,
        conceal = arrow,
        hl_group = "@org.table.delimiter",
      })
    end
    for i = 1, #line do
      if line:sub(i, i) == "|" then
        conceal(bufnr, row, i - 1, p.vert, "@org.table.delimiter")
      end
    end
  else
    for i = 1, #line do
      if line:sub(i, i) == "|" then
        conceal(bufnr, row, i - 1, p.vert, "@org.table.delimiter")
      end
    end
  end
end

local function decorate_table(bufnr, lines, row_first, row_last, p, cfg)
  for row = row_first, row_last do
    decorate_row(bufnr, row, lines[row + 1] or "", p, true)
  end
  if cfg.border_virtual ~= false then
    local first_line = lines[row_first + 1] or ""
    local first_pipes = pipe_positions(first_line)
    if #first_pipes >= 2 then
      local top = build_border_line(first_line, first_pipes, p, "top")
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row_first, 0, {
        virt_lines = { { { top, "@org.table.delimiter" } } },
        virt_lines_above = true,
      })
    end
    local last_line = lines[row_last + 1] or ""
    local last_pipes = pipe_positions(last_line)
    if #last_pipes >= 2 then
      local bot = build_border_line(last_line, last_pipes, p, "bot")
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row_last, 0, {
        virt_lines = { { { bot, "@org.table.delimiter" } } },
      })
    end
  end
end

function M.refresh(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local raw = (require("organ").config.modern or {}).table
  if not raw then
    return
  end
  local cfg = type(raw) == "table" and raw or {}
  local p = preset_for(cfg)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local row = 0
  while row < total do
    if is_table_line(lines[row + 1] or "") then
      local first = row
      while row < total and is_table_line(lines[row + 1] or "") do
        row = row + 1
      end
      decorate_table(bufnr, lines, first, row - 1, p, cfg)
    else
      row = row + 1
    end
  end
end

local _attached = {}

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if _attached[bufnr] then
    return
  end
  local raw = (require("organ").config.modern or {}).table
  if not raw then
    return
  end
  local cfg = type(raw) == "table" and raw or {}
  _attached[bufnr] = true
  local group = vim.api.nvim_create_augroup("organ_modern_table_" .. bufnr, { clear = true })
  -- Refresh events.  TextChangedI is intentionally OMITTED by
  -- default: re-running conceal placement on every keystroke makes
  -- the visible chars flicker as cells shift, which is more
  -- distracting than the brief out-of-date render between strokes.
  -- The buffer re-syncs the moment the user leaves insert mode.
  local events = { "BufReadPost", "TextChanged", "InsertLeave" }
  if cfg.pause_in_insert == false then
    events[#events + 1] = "TextChangedI"
  end
  vim.api.nvim_create_autocmd(events, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      _attached[bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  -- Concealment needs `conceallevel >= 2`.  Bump per-window unless
  -- the user has it set higher already.
  for _, win in ipairs(vim.fn.win_findbuf(bufnr) or {}) do
    if vim.api.nvim_get_option_value("conceallevel", { win = win }) < 2 then
      pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = win })
    end
  end
  M.refresh(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  _attached[bufnr] = nil
end

return M
