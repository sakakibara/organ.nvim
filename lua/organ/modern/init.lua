-- org-modern equivalent: composable visual upgrades for org buffers.
--
-- Each stage is its own module + config flag, so users opt into any subset:
--   modern = {
--     bullets      = true,  -- per-level headline bullets
--     blocks       = true,  -- src/quote/example block frames
--     pills        = true,  -- TODO keyword pills
--     priority     = true,  -- [#A] right-column flag
--     tags         = true,  -- :tag: right-column run
--     cookies      = true,  -- [1/3] right-column progress bar
--     checkboxes   = true,  -- - [ ] state icons
--     list_bullets = true,  -- - / + -> •
--     dates        = true,  -- <2025-...> glyph + muted
--     rule         = true,  -- ----- full-width line
--     directives   = true,  -- #+KEYWORD: dimmed
--     drawers      = true,  -- :PROPERTIES: dimmed
--     table        = true,  -- pipe-table conceal
--   }

local M = {}

-- The full element set, in attach order. Single source of truth for
-- attach / detach / enabled so a new element is wired in one place.
local ELEMENTS = {
  "bullets",
  "blocks",
  "pills",
  "priority",
  "tags",
  "cookies",
  "checkboxes",
  "list_bullets",
  "dates",
  "rule",
  "directives",
  "drawers",
  "table",
}

-- True when any modern element is enabled on `bufnr`. The ftplugin uses this
-- to decide whether to attach at all -- gating on a fixed subset would leave
-- an element that is enabled alone (e.g. only `checkboxes`) never rendering.
function M.enabled(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bc = require("organ.buf_config")
  for _, e in ipairs(ELEMENTS) do
    if bc.read(bufnr, "modern." .. e) then
      return true
    end
  end
  return false
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bc = require("organ.buf_config")
  for _, e in ipairs(ELEMENTS) do
    if bc.read(bufnr, "modern." .. e) then
      require("organ.modern." .. e).attach(bufnr)
    end
  end
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  for _, e in ipairs(ELEMENTS) do
    pcall(function()
      require("organ.modern." .. e).detach(bufnr)
    end)
  end
end

return M
