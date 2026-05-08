-- TODO + timestamp pill rendering (org-modern's pill style).
--
-- Approximates Emacs org-modern's `:inverse-video t` pill effect: the
-- existing @org.todo.* and @org.timestamp groups (which carry fg) get
-- `reverse = true` overlaid via fresh hl groups, so the keyword bytes
-- render as a solid block of color (the fg becomes the bg). Bold +
-- subtle padding via thin bar characters wraps each match.
--
-- This module is purely cosmetic — no buffer text changes, no conceals.
-- Highlight groups + extmark virt_text inserts.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_pills")

local function clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

-- Per-window saved conceallevel (we DON'T modify it for pills, but
-- keep the hook symmetric with bullets/blocks).
M._saved_conceallevel = M._saved_conceallevel or {}

local function register_pill_highlights()
  -- Inverse-video versions of the per-keyword TODO groups. We can't
  -- just override @org.todo.* directly — that would also affect plain
  -- text highlights elsewhere. So we register sibling pill groups and
  -- attach them via extmarks.
  --
  -- The pill background comes from the existing fg color of the
  -- TODO group via reverse=true (vim swaps fg ↔ bg for the cell).
  for _, kw in ipairs({
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
  }) do
    vim.api.nvim_set_hl(
      0,
      "@organ.modern.pill." .. kw,
      { link = "@org.todo." .. kw, default = true, reverse = true, bold = true }
    )
  end
  vim.api.nvim_set_hl(
    0,
    "@organ.modern.pill.timestamp",
    { link = "@org.timestamp", default = true, reverse = true }
  )
end

-- Place an extmark over byte range [col_start, col_end) with the
-- given hl group, so the keyword bytes render as a pill.
local function pill(bufnr, row, col_start, col_end, hl)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, col_start, {
    end_col = col_end,
    hl_group = hl,
    priority = 200, -- above the base TS highlight
  })
end

local TODO_KEYWORDS = nil
local function todo_keywords()
  if TODO_KEYWORDS then
    return TODO_KEYWORDS
  end
  local seq = (require("organ").config.todo or {}).sequence or {}
  TODO_KEYWORDS = {}
  for _, k in ipairs(seq) do
    if k ~= "|" then
      TODO_KEYWORDS[#TODO_KEYWORDS + 1] = k
    end
  end
  return TODO_KEYWORDS
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

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kws = todo_keywords()
  for i, line in ipairs(lines) do
    local row = i - 1
    -- TODO keyword on a headline: stars + space + keyword.
    local stars, kw_start_byte = line:match("^(%*+)%s()(%S+)")
    if stars then
      local _, _, kw = line:match("^%*+%s()(%S+)")
      _ = kw_start_byte -- unused; computed below differently
      local kw_start = #stars + 1 -- 0-based col of keyword start
      -- Match against configured sequence (not just any non-space).
      for _, k in ipairs(kws) do
        if
          line:sub(kw_start + 1, kw_start + #k) == k
          and (
            line:byte(kw_start + #k + 1) == 32 -- space follows
            or kw_start + #k == #line
          )
        then -- or end of line
          pill(bufnr, row, kw_start, kw_start + #k, "@organ.modern.pill." .. k:lower())
          break
        end
      end
    end

    -- Active timestamps: `<2026-05-04 Mon>` or `<2026-05-04 Mon 09:00>`.
    -- And inactive: `[2026-05-04 Mon]`.
    for s, e in line:gmatch("()<%d%d%d%d%-%d%d%-%d%d[^<>]*>()") do
      pill(bufnr, row, s - 1, e - 1, "@organ.modern.pill.timestamp")
    end
    for s, e in line:gmatch("()%[%d%d%d%d%-%d%d%-%d%d[^%[%]]*%]()") do
      pill(bufnr, row, s - 1, e - 1, "@organ.modern.pill.timestamp")
    end
  end
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  register_pill_highlights()
  apply(bufnr)
  local group = vim.api.nvim_create_augroup("organ_modern_pills_" .. bufnr, { clear = true })
  local trigger = require("organ.debounce").trailing(150, function(b)
    if vim.api.nvim_buf_is_valid(b) then
      apply(b)
    end
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      trigger(bufnr)
    end,
  })
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  clear(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_modern_pills_" .. bufnr)
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
