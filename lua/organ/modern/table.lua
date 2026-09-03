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

-- Build the top or bottom virtual border line, sized to match the
-- per-column display widths the data rows are visually padded to.
-- `widths` is a 1-indexed array of "source cell" display widths per
-- column (max across rows, leading/trailing whitespace included);
-- each segment between corners is `widths[c]` horizontal chars.
-- `indent` preserves lead-in whitespace so the border lines up under
-- indented tables.
local function build_border_line(indent, widths, p, kind)
  local out = { indent }
  out[#out + 1] = (kind == "top") and p.topl or p.botl
  for c, w in ipairs(widths) do
    out[#out + 1] = string.rep(p.horiz, w)
    if c < #widths then
      out[#out + 1] = (kind == "top") and p.topm or p.botm
    end
  end
  out[#out + 1] = (kind == "top") and p.topr or p.botr
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

-- Per-column target display width.  Pad-up-only strategy -- we never
-- shrink over-padded cells (conceal-based shrinking is unreliable
-- across nvim versions and renders inconsistently).  Target is the
-- max of (a) the widest pipe-to-pipe source cell display width and
-- (b) the natural ` content ` form (max trimmed-content + 2).  This
-- preserves an over-padded source row's width while still giving
-- tight sources (e.g. `|qty|`) the canonical 1-col-leading + content
-- + 1-col-trailing breathing room.
local function aligned_cell_widths(parsed_rows, table_lines)
  local widths = {}
  for ri, prow in ipairs(parsed_rows) do
    if not prow.sep then
      local line = table_lines[ri] or ""
      local pipes = pipe_positions(line)
      for c = 1, #pipes - 1 do
        local cell = line:sub(pipes[c] + 1, pipes[c + 1] - 1)
        local source_w = vim.fn.strdisplaywidth(cell)
        local trimmed = (cell:gsub("^%s+", ""):gsub("%s+$", ""))
        local content_w = vim.fn.strdisplaywidth(trimmed) + 2
        local w = source_w > content_w and source_w or content_w
        if not widths[c] or widths[c] < w then
          widths[c] = w
        end
      end
    end
  end
  return widths
end

-- Pad a single data-row cell (between pipes `lp` and `rp`, byte
-- positions 1-based) up to `target` display columns.  When the source
-- already has display width >= target, do nothing -- never shrink.
-- Source bytes stay; only inline virt_text spaces are added just
-- before the right pipe.
local function pad_cell_to(bufnr, row, line, lp, rp, target)
  local cell = line:sub(lp + 1, rp - 1)
  local current = vim.fn.strdisplaywidth(cell)
  local diff = target - current
  if diff <= 0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, rp - 1, {
    virt_text = { { string.rep(" ", diff) } },
    virt_text_pos = "inline",
  })
end

-- Rule-row segment boundaries: `|` AND `+` both delimit a rule
-- row's column segments (the source `+` is conceal-replaced with
-- the preset's cross by decorate_row).  Returns 1-based byte
-- positions of every boundary char.
local function rule_boundaries(line)
  local out = {}
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == "|" or c == "+" then
      out[#out + 1] = i
    end
  end
  return out
end

-- Pad a rule-row segment with the preset's horizontal char so the
-- divider extends to match the data-cell width of the same column.
-- Source `-` chars stay (decorate_row's per-char conceal converts
-- them to `─`); we only fill the deficit.  Pad-up-only -- never
-- shrink, matching the data-cell strategy.
local function pad_rule_segment_to(bufnr, row, lp, rp, target, p)
  local current = rp - lp - 1
  local diff = target - current
  if diff <= 0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, rp - 1, {
    virt_text = { { string.rep(p.horiz, diff), "@org.table.delimiter" } },
    virt_text_pos = "inline",
  })
end

-- Visual alignment pass: enforce per-column width across every row
-- of the table without modifying the buffer.  Uses tablature's
-- parser so the width math matches `tablature.align` exactly --
-- same widths the buffer would have if the user hit Tab.  Skips
-- silently on a parse failure (malformed table) so the existing
-- glyph conceal still runs.
-- Returns the per-column display widths the data rows are padded to,
-- or nil on parse failure.  Splitting this out from `decorate_alignment`
-- so `decorate_table` can use the same widths to size the virtual
-- top/bottom borders.
local function table_aligned_widths(lines, row_first, row_last)
  local table_lines = {}
  for r = row_first, row_last do
    table_lines[#table_lines + 1] = lines[r + 1] or ""
  end
  local ok, tab = pcall(require, "tablature")
  if not ok then
    return nil, nil
  end
  local parsed = nil
  pcall(function()
    parsed = tab.parse(table_lines, 1, { dialect = "org" })
  end)
  if not parsed or not parsed.rows then
    return nil, nil
  end
  -- Build the per-column max source-cell display width AND fill in
  -- zeros for any column index that didn't appear in a non-sep row
  -- (defensive: shouldn't happen for well-formed tables but keeps
  -- callers honest).
  local widths_map = aligned_cell_widths(parsed.rows, table_lines)
  if next(widths_map) == nil then
    return nil, nil
  end
  local ncols = 0
  for c, _ in pairs(widths_map) do
    if c > ncols then
      ncols = c
    end
  end
  local widths = {}
  for c = 1, ncols do
    widths[c] = widths_map[c] or 0
  end
  return widths, parsed
end

local function decorate_alignment(bufnr, lines, row_first, row_last, p, widths, parsed)
  if not (widths and parsed) then
    return
  end
  local table_lines = {}
  for r = row_first, row_last do
    table_lines[#table_lines + 1] = lines[r + 1] or ""
  end
  for ri, prow in ipairs(parsed.rows) do
    local row = row_first + ri - 1
    local line = table_lines[ri] or ""
    if prow.sep then
      local bounds = rule_boundaries(line)
      for c = 1, #bounds - 1 do
        pad_rule_segment_to(bufnr, row, bounds[c], bounds[c + 1], widths[c] or 0, p)
      end
    else
      local pipes = pipe_positions(line)
      for c = 1, #pipes - 1 do
        pad_cell_to(bufnr, row, line, pipes[c], pipes[c + 1], widths[c] or 0)
      end
    end
  end
end

local function decorate_table(bufnr, lines, row_first, row_last, p, cfg)
  for row = row_first, row_last do
    decorate_row(bufnr, row, lines[row + 1] or "", p, true)
  end
  local widths, parsed = table_aligned_widths(lines, row_first, row_last)
  decorate_alignment(bufnr, lines, row_first, row_last, p, widths, parsed)
  if cfg.border_virtual ~= false and widths and #widths > 0 then
    -- Use the aligned widths to build the virtual borders so they line
    -- up with the (post-pad) data rows -- not with the source pipe
    -- positions, which can be uneven for a misaligned source.
    local first_line = lines[row_first + 1] or ""
    local indent = first_line:match("^(%s*)") or ""
    local top = build_border_line(indent, widths, p, "top")
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row_first, 0, {
      virt_lines = { { { top, "@org.table.delimiter" } } },
      virt_lines_above = true,
    })
    local bot = build_border_line(indent, widths, p, "bot")
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row_last, 0, {
      virt_lines = { { { bot, "@org.table.delimiter" } } },
    })
  end
end

function M.refresh(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local raw = require("organ.buf_config").read(bufnr, "modern.table")
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
  local raw = require("organ.buf_config").read(bufnr, "modern.table")
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
  -- Trailing debounce: refresh walks every table in the buffer, parses
  -- each via tablature, and places extmarks per cell.  150ms means
  -- continuous typing skips refresh entirely and only fires once the
  -- user pauses -- much better than per-keystroke refresh on buffers
  -- with many tables.
  local trigger = require("organ.debounce").trailing(150, function(b)
    if vim.api.nvim_buf_is_valid(b) then
      M.refresh(b)
    end
  end)
  require("organ.errors").autocmd(events, {
    group = group,
    buffer = bufnr,
    callback = function()
      trigger(bufnr)
    end,
  })
  require("organ.errors").autocmd("BufWipeout", {
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
      pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = win, scope = "local" })
    end
  end
  M.refresh(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  _attached[bufnr] = nil
end

-- Reapply hook: react to live `modern.table` flips on this buffer.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local want = require("organ.buf_config").read(bufnr, "modern.table") and true or false
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
