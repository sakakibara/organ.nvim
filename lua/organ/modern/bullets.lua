-- Per-level headline bullets (org-modern's `org-modern-star`).
--
-- Replaces the trailing `*` of each headline's leading-star block
-- with a per-level glyph (cycled through a configurable list), and
-- conceals the leading N-1 stars as spaces. So:
--
--   *** Foo   →    ◈ Foo     (with 2 spaces of indent)
--   ** Bar    →    ○ Bar     (with 1 space)
--   * Baz     →    ◉ Baz
--
-- Self-contained: do NOT combine with `stars.lua` — both touch the
-- same byte range and the last-applied conceal wins (non-deterministic).
-- Users should pick one. The default config wires this in via
-- `modern.bullets = true`; `stars.hide = true` is the alternative.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_bullets")

-- org-modern's default cycle. Repeats for levels > 4.
local DEFAULT_GLYPHS = { "◉", "○", "◈", "◇" }

local function clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

local function get_glyphs()
  local cfg = (require("organ").config.modern or {})
  local b = cfg.bullets
  if type(b) == "table" and type(b.glyphs) == "table" and #b.glyphs > 0 then
    return b.glyphs
  end
  return DEFAULT_GLYPHS
end

-- Cached query (parsed once per session).
local _q
local function get_query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", "(headline) @h")
  if ok then
    _q = parsed
  end
  return _q
end

-- Configurable additional symbols for list bullets and checkboxes.
-- Mirrors org-bullets.nvim's `symbols.list` / `symbols.checkboxes`.
-- Off when the corresponding key is nil/false.
local function get_list_glyph()
  local cfg = (require("organ").config.modern or {})
  local b = cfg.bullets
  if type(b) == "table" and b.list ~= nil then
    return b.list
  end
  return "•" -- sensible default, matches org-bullets
end

local function get_checkbox_glyphs()
  local cfg = (require("organ").config.modern or {})
  local b = cfg.bullets
  local cb = (type(b) == "table" and b.checkboxes) or {}
  return {
    todo = cb.todo or "˟",
    done = cb.done or "✓",
    half = cb.half or "▣",
  }
end

local function apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  clear(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end
  local q = get_query()
  if not q then
    return
  end

  local glyphs = get_glyphs()
  for _, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
    local sr, sc = node:start()
    local ok_line, line = pcall(vim.api.nvim_buf_get_lines, bufnr, sr, sr + 1, false)
    if ok_line and line and line[1] then
      local stars = line[1]:match("^(%*+)") or ""
      local n = #stars
      if n >= 1 then
        -- Conceal leading N-1 stars as spaces.
        for i = 0, n - 2 do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, sr, sc + i, {
            end_col = sc + i + 1,
            conceal = " ",
          })
        end
        -- Conceal the trailing star with a level-specific glyph.
        local glyph = glyphs[((n - 1) % #glyphs) + 1]
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, sr, sc + n - 1, {
          end_col = sc + n,
          conceal = glyph,
        })
      end
    end
  end

  -- List-item bullets and checkboxes: scan all lines (cheap) for the
  -- standard `<indent>- [ ] text` / `<indent>+ [X] text` shapes and
  -- conceal the marker / checkbox char.
  local cb_glyphs = get_checkbox_glyphs()
  local list_glyph = get_list_glyph()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local indent_end, marker_end, marker = line:find("^(%s*)([%-%+])%s")
    if marker_end then
      _ = indent_end
      -- Conceal the bullet marker (- or +) with the list glyph.
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, i - 1, marker_end - 1, {
        end_col = marker_end,
        conceal = list_glyph,
      })
    end
    -- Checkbox: `[ ]` / `[X]` / `[x]` / `[-]` somewhere on the line.
    -- We only conceal inside list items (line that has a list marker
    -- OR is a numbered list `N.`/`N)`); checkboxes on plain text are
    -- left alone.
    if marker_end or line:match("^%s*%d+[%.%)]%s") then
      local s, e, ch = line:find("%[([ xX%-])%]")
      if s and ch then
        local g
        if ch == "X" or ch == "x" then
          g = cb_glyphs.done
        elseif ch == "-" then
          g = cb_glyphs.half
        else
          g = cb_glyphs.todo
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, i - 1, s - 1, {
          end_col = e,
          conceal = g,
        })
      end
    end
  end
end

-- Per-window saved conceallevel (window option, not buffer).
M._saved_conceallevel = M._saved_conceallevel or {}

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] == nil then
    M._saved_conceallevel[winid] = vim.wo.conceallevel
  end
  if vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end

  apply(bufnr)
  local group = vim.api.nvim_create_augroup("organ_modern_bullets_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      apply(bufnr)
    end,
  })
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  clear(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_modern_bullets_" .. bufnr)
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] ~= nil then
    vim.wo.conceallevel = M._saved_conceallevel[winid]
    M._saved_conceallevel[winid] = nil
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { limit = 1 })
  if #marks > 0 then
    M.detach(bufnr)
    return false
  end
  M.attach(bufnr)
  return true
end

M._apply = apply

return M
