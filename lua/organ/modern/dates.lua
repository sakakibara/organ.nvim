-- Timestamps / dates for modern mode.
--
-- `<2025-07-06 Sun>` (active) / `[2025-07-06 Sun]` (inactive) -> the brackets
-- are concealed, a calendar glyph (clock if the stamp carries a time) is
-- prefixed inline, and the date text is muted; active reads brighter than
-- inactive. Covers body (org_inline) timestamps and headline-title stamps
-- (the inline grammar is not injected into titles, so those are byte-scanned).
-- Rendered through the persistent engine. This is the sole timestamp renderer
-- in modern mode -- pills.lua handles only TODO keywords.

local M = {}

-- kind -> source color group (active brighter, inactive dim). Recomputed
-- after ColorScheme.
local KIND_GROUP = { active = "Number", inactive = "Comment" }
local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local resolved = require("organ.highlights").resolved_fg
  for kind, group in pairs(KIND_GROUP) do
    local fg = resolved(group)
    if fg then
      vim.api.nvim_set_hl(0, "@organ.modern.date." .. kind, { fg = fg })
    end
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_dates_hl", { clear = true }),
  callback = function()
    _hl_dirty = true
  end,
})

-- Emit one timestamp: conceal the outer brackets, prefix the glyph inline,
-- and mute the inner text. `sc`/`ec` bound the whole `<...>`/`[...]` node.
local function emit(bufnr, ns, row, sc, ec, text)
  local active = text:sub(1, 1) == "<"
  local kind = active and "active" or "inactive"
  local hl = "@organ.modern.date." .. kind
  local timed = text:match("%d%d?:%d%d") ~= nil
  local glyph = require("organ.modern.glyphs").get(timed and "date.clock" or "date.calendar", bufnr)

  if glyph == "" then
    -- ascii / no-glyph: color the whole stamp, keep brackets.
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, sc, {
      end_col = ec,
      hl_group = hl,
      priority = 200,
    })
    return
  end

  -- Conceal opening + closing bracket (1 byte each).
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, sc, {
    end_col = sc + 1,
    conceal = "",
    priority = 200,
  })
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, ec - 1, {
    end_col = ec,
    conceal = "",
    priority = 200,
  })
  -- Prefix the glyph + a space inline where the opening bracket was.
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, sc, {
    virt_text = { { glyph .. " ", hl } },
    virt_text_pos = "inline",
    priority = 200,
  })
  -- Mute the inner date text.
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, sc + 1, {
    end_col = ec - 1,
    hl_group = hl,
    priority = 200,
  })
end

local _q_title
local function title_query()
  if _q_title then
    return _q_title
  end
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org",
    [[
    (headline_line title: (title) @title)
  ]]
  )
  if ok then
    _q_title = parsed
  end
  return _q_title
end

local _q_inline
local function inline_query()
  if _q_inline then
    return _q_inline
  end
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org_inline",
    [[
    (timestamp_active) @ts
    (timestamp_inactive) @ts
    (timestamp_range_active) @ts
    (timestamp_range_inactive) @ts
  ]]
  )
  if ok then
    _q_inline = parsed
  end
  return _q_inline
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.dates") then
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
  ensure_highlights()

  local ns = require("organ.modern.render").ns

  -- Headline-title stamps: byte-scan the title node (inline grammar is not
  -- injected into headline titles).
  local qt = title_query()
  if qt then
    for _, node in qt:iter_captures(tree:root(), bufnr, top, bot) do
      local sr, sc, er = node:range()
      if sr == er then
        local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
        if ok_text and type(text) == "string" then
          for s, stamp, e in text:gmatch("()(<%d%d%d%d%-%d%d%-%d%d[^<>\n]*>)()") do
            emit(bufnr, ns, sr, sc + s - 1, sc + e - 1, stamp)
          end
          for s, stamp, e in text:gmatch("()(%[%d%d%d%d%-%d%d%-%d%d[^%[%]\n]*%])()") do
            emit(bufnr, ns, sr, sc + s - 1, sc + e - 1, stamp)
          end
        end
      end
    end
  end

  -- Body stamps via the injected inline grammar.
  local qi = inline_query()
  if qi then
    parser:for_each_tree(function(itree, ltree)
      if ltree:lang() ~= "org_inline" then
        return
      end
      local rsr, _, rer = itree:root():range()
      if rer < top or rsr > bot then
        return
      end
      for _, node in qi:iter_captures(itree:root(), bufnr, top, bot) do
        local sr, sc, er, ec = node:range()
        if sr == er then
          local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
          if ok_text and type(text) == "string" then
            emit(bufnr, ns, sr, sc, ec, text)
          end
        end
      end
    end)
  end
end

require("organ.modern.render").register("dates", render)

function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  _hl_dirty = true
  require("organ.modern.render").attach(bufnr, "dates")
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr, "dates")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.dates")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.dates") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
