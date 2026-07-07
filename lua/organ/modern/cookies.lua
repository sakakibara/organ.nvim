-- Statistics / progress cookies for modern mode.
--
-- `* Project [1/3]` (or `[33%]`) -> the cookie is concealed in the buffer
-- and re-emitted in the right-aligned metadata column (between priority and
-- tags) as a mini progress bar plus the fraction/percent, gradient-colored
-- by completion: 0 -> muted, partial -> warn, complete -> ok. Rendered
-- through the persistent engine and composed by organ.modern.layout.

local M = {}

local DEFAULT_BAR_WIDTH = 6

-- Completion-state hl groups (fg only). Recomputed after ColorScheme.
local STATE_GROUP = {
  empty = "Comment",
  partial = "DiagnosticWarn",
  full = "DiagnosticOk",
  track = "Comment",
}
local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local resolved = require("organ.highlights").resolved_fg
  for state, group in pairs(STATE_GROUP) do
    local fg = resolved(group)
    if fg then
      vim.api.nvim_set_hl(0, "@organ.modern.cookie." .. state, { fg = fg })
    end
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_cookies_hl", { clear = true }),
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
    (headline_line cookie: (statistics_cookie) @c)
  ]])
  if ok then
    _q = parsed
  end
  return _q
end

-- Parse `[n/m]` or `[p%]` -> fraction in [0,1] and the display label, or nil.
local function parse_cookie(text)
  local n, d = text:match("%[(%d+)/(%d+)%]")
  if n then
    n, d = tonumber(n), tonumber(d)
    local frac = (d and d > 0) and (n / d) or 0
    return frac, n .. "/" .. d
  end
  local p = text:match("%[(%d+)%%%]")
  if p then
    p = tonumber(p)
    return math.max(0, math.min(1, p / 100)), p .. "%"
  end
  return nil
end

local function state_for(frac)
  if frac <= 0 then
    return "empty"
  elseif frac >= 1 then
    return "full"
  end
  return "partial"
end

local function bar_width(bufnr)
  local cfg = require("organ.buf_config").read(bufnr, "modern.cookies.bar_width")
  if type(cfg) == "number" and cfg > 0 then
    return math.floor(cfg)
  end
  return DEFAULT_BAR_WIDTH
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.cookies") then
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
  ensure_highlights()

  local ns = require("organ.modern.render").ns
  local layout = require("organ.modern.layout")
  local glyphs = require("organ.modern.glyphs")
  local width = bar_width(bufnr)
  local g_left = glyphs.get("cookie.bar.left", bufnr)
  local g_right = glyphs.get("cookie.bar.right", bufnr)
  local g_fill = glyphs.get("cookie.bar.fill", bufnr)
  local g_track = glyphs.get("cookie.bar.track", bufnr)

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc, er, ec = node:range()
    if sr == er then
      local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
      local frac, label = nil, nil
      if ok_text and type(text) == "string" then
        frac, label = parse_cookie(text)
      end
      if frac then
        vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
          end_col = ec,
          conceal = "",
          priority = 200,
        })
        local filled = math.floor(frac * width + 0.5)
        filled = math.max(0, math.min(width, filled))
        local state = state_for(frac)
        local fill_hl = "@organ.modern.cookie." .. state
        local track_hl = "@organ.modern.cookie.track"
        local chunks = {
          { g_left, track_hl },
          { string.rep(g_fill, filled), fill_hl },
          { string.rep(g_track, width - filled), track_hl },
          { g_right, track_hl },
          { " " .. label, fill_hl },
        }
        layout.add(bufnr, sr, layout.SLOT.cookies, chunks)
      end
    end
  end
end

require("organ.modern.render").register("cookies", render)

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
  local on = require("organ.buf_config").toggle(bufnr, "modern.cookies")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.cookies") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
