-- TODO keyword pills (org-modern's inverse-video style, terminal-first).
--
-- A TODO/state keyword renders as a rounded badge: the keyword bytes get a
-- reversed body (semantic bucket color) plus Nerd Font half-circle caps
-- inserted inline at the keyword boundaries, so the badge is spaced from
-- the bullet and the title. Timestamps are rendered by organ.modern.dates.
--
-- Rendered through `organ.modern.render` (the persistent-extmark engine),
-- NOT the ephemeral decoration provider: the caps are inline virt_text,
-- which the ephemeral provider silently drops. The engine places
-- non-ephemeral marks over the visible range on edit / scroll / colorscheme.

local M = {}

local PILL_KEYWORDS = {
  "todo",
  "next",
  "wait",
  "waiting",
  "hold",
  "proj",
  "started",
  "done",
  "cancelled",
  "canceled",
  "closed",
}

-- Badge body + cap groups per keyword and for timestamps, via the shared
-- badge primitive (resolves the color and applies reverse without link --
-- nvim_set_hl drops gui attributes when link is present).
local function register_pill_highlights()
  local badge = require("organ.modern.badge")
  for _, kw in ipairs(PILL_KEYWORDS) do
    badge.groups("pill." .. kw, "@org.todo." .. kw)
  end
end

-- Pill hl groups depend on live colors; re-derive lazily so a ColorScheme
-- (which re-sets @org.todo.* via organ.highlights first) is picked up.
local _pill_hl_dirty = true
local function ensure_pill_highlights()
  if not _pill_hl_dirty then
    return
  end
  register_pill_highlights()
  _pill_hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_pills_hl", { clear = true }),
  callback = function()
    _pill_hl_dirty = true
  end,
})

local _q_headline
local function get_headline_query()
  if _q_headline then
    return _q_headline
  end
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org",
    [[
      (headline_line todo: (todo) @kw)
    ]]
  )
  if ok then
    _q_headline = parsed
  end
  return _q_headline
end

local function todo_keywords_set(bufnr)
  local todo = require("organ.todo")
  local set = {}
  for _, k in ipairs(todo.all_keywords(todo.effective_sequences(bufnr))) do
    set[k] = true
  end
  return set
end

-- Rounded caps for keyword pills; box mode (modern.pill_caps = false) forces
-- flat (capless) badges.
local function pill_caps(bufnr)
  if require("organ.buf_config").read(bufnr, "modern.pill_caps") == false then
    return "", ""
  end
  local glyphs = require("organ.modern.glyphs")
  return glyphs.get("pill.cap.left", bufnr), glyphs.get("pill.cap.right", bufnr)
end

local function emit_pill(bufnr, row, sc, ec, kw_lower)
  local left, right = pill_caps(bufnr)
  require("organ.modern.badge").emit(require("organ.modern.render").ns, bufnr, row, sc, ec, {
    body_hl = "@organ.modern.badge.pill." .. kw_lower,
    cap_hl = "@organ.modern.badgecap.pill." .. kw_lower,
    left_cap = left,
    right_cap = right,
  })
end

-- Engine renderer: place pill marks for headline TODO keywords in the
-- [top, bot) row range. Self-gates on modern.pills.
local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.pills") then
    return
  end
  ensure_pill_highlights()
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    return
  end
  local trees = parser:parse({ top, bot })
  local tree = trees and trees[1]
  if not tree then
    return
  end

  local kw_set = todo_keywords_set(bufnr)
  local q = get_headline_query()
  if q then
    for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
      local sr, sc, er, ec = node:range()
      if sr == er then
        local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
        if ok_text and type(text) == "string" and kw_set[text] then
          emit_pill(bufnr, sr, sc, ec, text:lower())
        end
      end
    end
  end
end

require("organ.modern.render").register("pills", render)

-- Test-facing: render the whole buffer synchronously into the engine
-- namespace (non-ephemeral marks, queryable via nvim_buf_get_extmarks).
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

-- Foldtext helper. A closed fold renders foldtext, not the real line, so the
-- pill extmarks never reach it. Given a headline's TODO keyword, return the
-- cap glyphs + hl groups the foldtext builder needs to draw the same pill, so
-- a folded heading matches an expanded one. Returns nil when pills are off.
function M.fold_pieces(bufnr, keyword)
  if not require("organ.buf_config").read(bufnr, "modern.pills") then
    return nil
  end
  ensure_pill_highlights()
  local kw = keyword:lower()
  local left, right = pill_caps(bufnr)
  return {
    body_hl = "@organ.modern.badge.pill." .. kw,
    cap_hl = "@organ.modern.badgecap.pill." .. kw,
    left = left,
    right = right,
  }
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  register_pill_highlights()
  require("organ.modern.render").attach(bufnr, "pills")
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr, "pills")
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.pills")
  return on and true or false
end

-- React to live `modern.pills` flips.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.pills") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
