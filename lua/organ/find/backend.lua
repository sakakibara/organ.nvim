-- Backend adapter contract for organ.nvim find pickers.
--
-- An adapter exposes one function:
--   pick(items, opts)
--     items[i] = { id, title, file_path, line_start, level, todo_state,
--                  priority, tags, display, match_fields }
--     opts = {
--       prompt         = string,
--       actions        = { [name] = function(item) end },
--       default_action = name,
--       keymaps        = { ["<C-s>"] = "split", ... },
--       create         = function(query) end | nil,
--     }
--
-- See lua/organ/find/backends/snacks.lua for the built-in adapter.

local M = {}

-- A no-op adapter used by tests when the user wants to capture invocations
-- without spinning up a real picker. Selected via:
--   require("organ").setup({ find = { backend = "_test_stub" } })
M._test_stub = {}
function M._test_stub.pick(items, opts)
  M._test_stub.last = { items = items, opts = opts }
end

return M
