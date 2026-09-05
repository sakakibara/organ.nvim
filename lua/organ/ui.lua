-- Shared UI helpers used by every floating/special buffer.
--
-- M.set_winbar(winid, hints, opts)
--   Renders a one-line winbar built from a list of (lhs, label) pairs:
--     hints = { { "ZZ", "finalise" }, { "ZQ", "cancel" } }
--   Plus an optional opts.title (rendered with OrganUiTitle highlight) and
--   opts.suffix (raw winbar text appended after the hint list).
--
-- M.register_highlights()
--   One-shot registration of the default highlight links the winbar uses.
--   Called by every set_winbar() invocation; idempotent.

local M = {}

local _hl_done = false
local function register_highlights()
  if _hl_done then
    return
  end
  _hl_done = true
  vim.api.nvim_set_hl(0, "OrganUiTitle", { link = "Title", default = true, bold = true })
  vim.api.nvim_set_hl(0, "OrganUiKey", { link = "Special", default = true, bold = true })
  vim.api.nvim_set_hl(0, "OrganUiSep", { link = "Comment", default = true })
end

-- Render a winbar string from {{lhs, label}, ...} pairs.  When
-- `opts.compact` is true, drops the title and per-pair labels --
-- shows just the bracketed key glyphs separated by spaces, suited
-- to narrow sidebar windows.
function M.format_hints(hints, opts)
  opts = opts or {}
  local parts = {}
  if opts.compact then
    -- Compact: just key glyphs, single-space separated, no title.
    for i, pair in ipairs(hints) do
      if i > 1 then
        parts[#parts + 1] = " "
      end
      parts[#parts + 1] = "%#OrganUiKey#" .. pair[1] .. "%*"
    end
    return table.concat(parts)
  end
  if opts.title and opts.title ~= "" then
    parts[#parts + 1] = "%#OrganUiTitle#" .. opts.title .. "%*"
    parts[#parts + 1] = "  "
  end
  for i, pair in ipairs(hints) do
    if i > 1 then
      parts[#parts + 1] = "%#OrganUiSep#  ·  %*"
    end
    local lhs, label = pair[1], pair[2]
    parts[#parts + 1] = "%#OrganUiKey#" .. lhs .. "%* " .. label
  end
  if opts.suffix then
    parts[#parts + 1] = opts.suffix
  end
  return table.concat(parts)
end

-- Visible cell width of a winbar string (statusline format codes
-- like `%#Foo#` and `%*` count zero, the literal text counts via
-- strdisplaywidth).
local function visible_width(s)
  local stripped = s:gsub("%%#[^#]*#", ""):gsub("%%%*", "")
  return vim.fn.strdisplaywidth(stripped)
end

function M.set_winbar(winid, hints, opts)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  register_highlights()
  opts = opts or {}
  pcall(function()
    -- Try the full format first; fall back to compact when it
    -- doesn't fit the window.  Skip the fit check when the caller
    -- has explicitly asked for compact.
    local full = M.format_hints(hints, opts)
    local win_w = vim.api.nvim_win_get_width(winid)
    if not opts.compact and visible_width(full) > win_w then
      full = M.format_hints(hints, vim.tbl_extend("force", opts, { compact = true }))
    end
    vim.api.nvim_set_option_value("winbar", full, { win = winid, scope = "local" })
  end)
end

return M
