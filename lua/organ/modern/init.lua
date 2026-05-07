-- org-modern equivalent: composable visual upgrades for org buffers.
--
-- Each stage is its own module + config flag, so users can opt into
-- bullets without committing to block frames or pills:
--   modern = {
--     bullets = true,    -- per-level headline bullets (◉ ○ ◈ ◇ …)
--     blocks  = true,    -- src/quote/example block frames
--     pills   = true,    -- TODO/timestamp pill rendering
--     table   = true,    -- pipe-table conceal (│ ─ ┼ + virt borders)
--   }

local M = {}

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg = require("organ").config.modern or {}
  if cfg.bullets then
    require("organ.modern.bullets").attach(bufnr)
  end
  if cfg.blocks then
    require("organ.modern.blocks").attach(bufnr)
  end
  if cfg.pills then
    require("organ.modern.pills").attach(bufnr)
  end
  if cfg.table then
    require("organ.modern.table").attach(bufnr)
  end
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  for _, sub in ipairs({ "bullets", "blocks", "pills", "table" }) do
    pcall(function()
      require("organ.modern." .. sub).detach(bufnr)
    end)
  end
end

return M
