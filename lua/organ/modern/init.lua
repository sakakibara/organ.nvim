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
  local bc = require("organ.buf_config")
  if bc.read(bufnr, "modern.bullets") then
    require("organ.modern.bullets").attach(bufnr)
  end
  if bc.read(bufnr, "modern.blocks") then
    require("organ.modern.blocks").attach(bufnr)
  end
  if bc.read(bufnr, "modern.pills") then
    require("organ.modern.pills").attach(bufnr)
  end
  if bc.read(bufnr, "modern.priority") then
    require("organ.modern.priority").attach(bufnr)
  end
  if bc.read(bufnr, "modern.tags") then
    require("organ.modern.tags").attach(bufnr)
  end
  if bc.read(bufnr, "modern.cookies") then
    require("organ.modern.cookies").attach(bufnr)
  end
  if bc.read(bufnr, "modern.checkboxes") then
    require("organ.modern.checkboxes").attach(bufnr)
  end
  if bc.read(bufnr, "modern.list_bullets") then
    require("organ.modern.list_bullets").attach(bufnr)
  end
  if bc.read(bufnr, "modern.dates") then
    require("organ.modern.dates").attach(bufnr)
  end
  if bc.read(bufnr, "modern.rule") then
    require("organ.modern.rule").attach(bufnr)
  end
  if bc.read(bufnr, "modern.table") then
    require("organ.modern.table").attach(bufnr)
  end
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  for _, sub in ipairs({ "bullets", "blocks", "pills", "priority", "tags", "cookies", "checkboxes", "list_bullets", "dates", "rule", "table" }) do
    pcall(function()
      require("organ.modern." .. sub).detach(bufnr)
    end)
  end
end

return M
