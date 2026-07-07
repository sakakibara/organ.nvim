-- Priority cookies for modern mode.
--
-- `* [#A] Title` -> the `[#A]` is concealed in the buffer and re-emitted in
-- the right-aligned metadata column as a flag glyph + the rank letter,
-- colored by rank. Rendered through the persistent engine (organ.modern.
-- render) and composed by organ.modern.layout so priority sits leftmost in
-- the right column (slot < cookies < tags).

local M = {}

-- Rank -> semantic color group (fallbacks resolved by nvim's hl chain).
local RANK_GROUP = {
  a = "DiagnosticError",
  b = "DiagnosticWarn",
  c = "DiagnosticHint",
}
local MUTED_GROUP = "Comment"

local function group_for(rank)
  return RANK_GROUP[rank] or MUTED_GROUP
end

-- @organ.modern.priority.<rank> = { fg = resolved rank color }. Registered
-- for the ranks actually seen plus a,b,c; re-derived after ColorScheme.
local _hl_dirty = true
local function ensure_highlights(ranks)
  if not _hl_dirty then
    return
  end
  local resolved = require("organ.highlights").resolved_fg
  for rank in pairs(ranks) do
    local fg = resolved(group_for(rank))
    if fg then
      vim.api.nvim_set_hl(0, "@organ.modern.priority." .. rank, { fg = fg })
    end
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_priority_hl", { clear = true }),
  callback = function()
    _hl_dirty = true
  end,
})

local _q
local function query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", [[
    (headline_line priority: (priority) @p)
  ]])
  if ok then
    _q = parsed
  end
  return _q
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.priority") then
    return
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    return
  end
  local trees = parser:parse({ top, bot })
  local tree = trees and trees[1]
  if not tree then
    return
  end
  local q = query()
  if not q then
    return
  end

  local ns = require("organ.modern.render").ns
  local layout = require("organ.modern.layout")
  local glyphs = require("organ.modern.glyphs")

  -- First pass: collect ranks so highlight groups exist before emit.
  local hits = {}
  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc, er, ec = node:range()
    if sr == er then
      local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
      local rank = ok_text and type(text) == "string" and text:match("%[#(%w)%]")
      if rank then
        hits[#hits + 1] = { row = sr, sc = sc, ec = ec, rank = rank:lower() }
      end
    end
  end
  local ranks = {}
  for _, h in ipairs(hits) do
    ranks[h.rank] = true
  end
  ranks.a, ranks.b, ranks.c = true, true, true
  ensure_highlights(ranks)

  local flag = glyphs.get("priority.flag", bufnr)
  for _, h in ipairs(hits) do
    -- Conceal the raw [#A] inline.
    vim.api.nvim_buf_set_extmark(bufnr, ns, h.row, h.sc, {
      end_col = h.ec,
      conceal = "",
      priority = 200,
    })
    -- Emit the right-column segment: flag glyph + rank letter.
    local hl = "@organ.modern.priority." .. h.rank
    local label = (flag ~= "" and (flag .. " ") or "") .. h.rank:upper()
    layout.add(bufnr, h.row, layout.SLOT.priority, { { label, hl } })
  end
end

require("organ.modern.render").register("priority", render)

function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
  require("organ.modern.layout").flush(bufnr, ns)
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  _hl_dirty = true
  require("organ.modern.render").attach(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.priority")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.priority") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
