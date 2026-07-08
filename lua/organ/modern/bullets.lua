-- Per-level headline bullets (org-modern's `org-modern-star`).
--
-- Replaces the trailing `*` of each headline's leading-star block with a
-- per-level glyph (org-modern's `◉ ○ ◈ ◇` ramp by default), and conceals
-- the leading N-1 stars as spaces:
--
--   *** Foo   ->     <g3> Foo   (2 spaces of indent)
--   ** Bar    ->     <g2> Bar   (1 space)
--   * Baz     ->     <g1> Baz
--
-- Rendered through `organ.modern.render` (the persistent engine). Plain list
-- bullets and checkboxes are separate elements (organ.modern.list_bullets /
-- organ.modern.checkboxes); this module handles only headline stars.
--
-- Self-contained: do NOT combine with `stars.lua` -- both conceal the same
-- byte range and the last-applied conceal wins. Pick one (`modern.bullets`
-- or `stars.hide`). The engine raises `conceallevel` for its conceal marks.

local M = {}

local function bcfg(bufnr, path)
  return require("organ.buf_config").read(bufnr, path)
end

-- The per-level glyph cycle. A user `{ glyphs = {...} }` override wins;
-- otherwise the registry ramp (nerd or ascii per `modern.nerd_font`).
local function get_glyphs(bufnr)
  local b = bcfg(bufnr, "modern.bullets")
  if type(b) == "table" and type(b.glyphs) == "table" and #b.glyphs > 0 then
    return b.glyphs
  end
  local g = require("organ.modern.glyphs")
  return {
    g.get("bullet.1", bufnr),
    g.get("bullet.2", bufnr),
    g.get("bullet.3", bufnr),
    g.get("bullet.4", bufnr),
  }
end

local _q
local function query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", "(headline) @h")
  if ok then
    _q = parsed
  end
  return _q
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not bcfg(bufnr, "modern.bullets") then
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
  local glyphs = get_glyphs(bufnr)
  local heading_title_hl = require("organ.highlights").heading_title_hl

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc = node:start()
    if sr >= top and sr < bot then
      local ok_line, line = pcall(vim.api.nvim_buf_get_lines, bufnr, sr, sr + 1, false)
      if ok_line and line and line[1] then
        local stars = line[1]:match("^(%*+)") or ""
        local n = #stars
        if n >= 1 then
          for i = 0, n - 2 do
            vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc + i, {
              end_col = sc + i + 1,
              conceal = " ",
              priority = 200,
            })
          end
          local glyph = glyphs[((n - 1) % #glyphs) + 1]
          vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc + n - 1, {
            end_col = sc + n,
            conceal = glyph,
            hl_group = heading_title_hl(n),
            priority = 200,
          })
        end
      end
    end
  end
end

require("organ.modern.render").register("bullets", render)

function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

-- Display string that replaces a headline's leading `level`-star block:
-- (level-1) spaces + the per-level glyph. A closed fold renders foldtext
-- instead of the real line, so the conceal never reaches it; the foldtext
-- renderer calls this to show the same bullet on a folded head.
function M.star_display(bufnr, level)
  if not level or level < 1 then
    return nil
  end
  local glyphs = get_glyphs(bufnr)
  local glyph = glyphs[((level - 1) % #glyphs) + 1]
  return string.rep(" ", level - 1) .. glyph
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").attach(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.bullets")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if bcfg(bufnr, "modern.bullets") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
