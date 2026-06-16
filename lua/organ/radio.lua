-- Editor-side radio links: highlight + follow.  Reuses the matcher and
-- target normalization from `organ.ast.radio` (the export-side core) so
-- the buffer view agrees with what export resolves.  Distinct from
-- `organ.ast.radio`: this module is buffer/tree-based, that one is AST.

local ast_radio = require("organ.ast.radio")

local M = {}

-- Per-buffer definitions cache, rebuilt when changedtick advances.
local _cache = {}

-- Per-frame state: matcher + precomputed skip spans, keyed by bufnr.
local _frame = {}

-- Scan all buffer lines for <<<phrase>>> definitions.  Returns the raw
-- phrase list and a map phrase:lower() -> { line (1-based), col (0-based) }
-- of the first definition (for follow to jump to).
local function scan_defs(bufnr)
  local raw, defs = {}, {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local pos = 1
    while true do
      local s, e, phrase = line:find("<<<(.-)>>>", pos)
      if not s then
        break
      end
      if phrase:match("%S") then
        raw[#raw + 1] = phrase
        local key = phrase:lower()
        if not defs[key] then
          defs[key] = { line = i, col = s - 1 }
        end
      end
      pos = e + 1
    end
  end
  return raw, defs
end

-- Cache entry for bufnr, rebuilt on changedtick.
function M.targets(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return { phrases = {}, defs = {}, matcher = ast_radio.build_matcher({}) }
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = _cache[bufnr]
  if c and c.tick == tick then
    return c
  end
  local raw, defs = scan_defs(bufnr)
  local phrases = ast_radio.normalize_targets(raw)
  c = {
    tick = tick,
    phrases = phrases,
    defs = defs,
    matcher = ast_radio.build_matcher(phrases),
  }
  _cache[bufnr] = c
  return c
end

function M.invalidate(bufnr)
  _cache[bufnr or vim.api.nvim_get_current_buf()] = nil
end

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = vim.api.nvim_create_augroup("organ_radio_cache", { clear = true }),
  callback = function(ev)
    _cache[ev.buf] = nil
    _frame[ev.buf] = nil
  end,
})

local NS = vim.api.nvim_create_namespace("organ_radio")
local HL = "@organ.radio"

local SKIP = {
  code = true,
  verbatim = true,
  link_regular = true,
  link_plain = true,
  link_angle = true,
  link_radio = true,
}

-- Byte spans on `row` (0-based) covered by org_inline nodes whose text is
-- not linkifiable (code/verbatim/existing links/the <<<def>>> itself).
local function skip_spans(bufnr, row)
  local spans = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return spans
  end
  for _, child in pairs(parser:children()) do
    if child:lang() == "org_inline" then
      for _, tree in ipairs(child:trees() or {}) do
        local function walk(n)
          if SKIP[n:type()] then
            local sr, sc, er, ec = n:range()
            if sr <= row and er >= row then
              local lo = (sr == row) and sc or 0
              local hi = (er == row) and ec or math.huge
              spans[#spans + 1] = { lo, hi }
            end
          end
          for c in n:iter_children() do
            walk(c)
          end
        end
        walk(tree:root())
      end
    end
  end
  return spans
end

-- Collect skip spans for every row in [top, bot] in ONE walk over the
-- org_inline trees overlapping that range (the viewport), gated like
-- conceal so the redraw path never walks the full injection forest.
-- Returns row (0-based) -> { {lo, hi}, ... }.
local function collect_skip_spans(bufnr, top, bot)
  local by_row = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return by_row
  end
  for _, child in pairs(parser:children()) do
    if child:lang() == "org_inline" then
      for _, tree in ipairs(child:trees() or {}) do
        local root = tree:root()
        local rsr, _, rer, _ = root:range()
        if rer >= top and rsr <= bot then
          local function walk(n)
            if SKIP[n:type()] then
              local sr, sc, er, ec = n:range()
              local lo_row = math.max(sr, top)
              local hi_row = math.min(er, bot)
              for r = lo_row, hi_row do
                local lo = (sr == r) and sc or 0
                local hi = (er == r) and ec or math.huge
                by_row[r] = by_row[r] or {}
                by_row[r][#by_row[r] + 1] = { lo, hi }
              end
            end
            for c in n:iter_children() do
              walk(c)
            end
          end
          walk(root)
        end
      end
    end
  end
  return by_row
end

-- Occurrences in `line_text` after tree-aware scope: { {start0, stop0, phrase}, ... }
-- (start0 0-based inclusive, stop0 0-based exclusive). `spans` is the list of
-- skip ranges on this row (precomputed). Shared by on_line / _apply / def_at.
local function occurrences(line_text, matcher, spans)
  local out = {}
  if line_text == "" then
    return out
  end
  spans = spans or {}
  local s = line_text
  local base = 0
  while true do
    local st, sp, phrase = matcher(s)
    if not st or sp < st then
      break
    end
    local start0 = base + st - 1
    local stop0 = base + sp
    local skipped = false
    for _, span in ipairs(spans) do
      if start0 < span[2] and stop0 > span[1] then
        skipped = true
        break
      end
    end
    if not skipped then
      out[#out + 1] = { start0, stop0, phrase }
    end
    base = stop0
    s = line_text:sub(stop0 + 1)
  end
  return out
end

local function enabled(bufnr)
  return require("organ.buf_config").read(bufnr, "radio.enabled") ~= false
end

local function on_win(bufnr, _winid, topline, botline)
  if not enabled(bufnr) then
    _frame[bufnr] = nil
    return
  end
  require("organ.decoration").get_tree(bufnr)
  local t = M.targets(bufnr)
  if #t.phrases == 0 then
    _frame[bufnr] = nil
    return
  end
  _frame[bufnr] = { matcher = t.matcher, skip = collect_skip_spans(bufnr, topline, botline) }
end

local function on_line(bufnr, _winid, row)
  local f = _frame[bufnr]
  if not f then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  for _, occ in ipairs(occurrences(line, f.matcher, f.skip[row])) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, occ[1], {
      end_col = occ[2],
      hl_group = HL,
      ephemeral = true,
    })
  end
end

require("organ.decoration").register({
  name = "radio",
  ns = NS,
  enabled = enabled,
  on_win = on_win,
  on_line = on_line,
})

-- ftplugin entrypoint (registration already happened at module load).
function M.attach(_bufnr) end

-- Test entrypoint: drive the whole buffer with non-ephemeral extmarks so
-- nvim_buf_get_extmarks sees them.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  if not enabled(bufnr) then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  require("organ.decoration").get_tree(bufnr)
  local t = M.targets(bufnr)
  if #t.phrases == 0 then
    return
  end
  local skip = collect_skip_spans(bufnr, 0, n - 1)
  for row = 0, n - 1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    for _, occ in ipairs(occurrences(line, t.matcher, skip[row])) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, occ[1], {
        end_col = occ[2],
        hl_group = HL,
      })
    end
  end
end

-- Definition position { line, col } for the radio occurrence under
-- (line 1-based, col 1-based), or nil. The definition is a link_radio
-- node, so the tree-aware scope already excludes it.
function M.def_at(bufnr, line, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not enabled(bufnr) then
    return nil
  end
  local t = M.targets(bufnr)
  if #t.phrases == 0 then
    return nil
  end
  require("organ.decoration").get_tree(bufnr)
  local row = line - 1
  local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local col0 = col - 1
  local spans = skip_spans(bufnr, row)
  for _, occ in ipairs(occurrences(text, t.matcher, spans)) do
    if col0 >= occ[1] and col0 < occ[2] then
      return t.defs[occ[3]:lower()]
    end
  end
  return nil
end

return M
