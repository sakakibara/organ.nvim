-- Right-column metadata composer for modern mode.
--
-- Priority, statistics cookies, and tags all live in a right-aligned column
-- to the right of the headline. Emitting each as its own right_align mark
-- would stack them ambiguously and fight over spacing, so element renderers
-- instead hand their rendered chunk list to this composer, which accumulates
-- per row during a refresh and flushes ONE right_align extmark per row --
-- segments ordered by slot (priority, cookies, tags) and space-separated.
--
-- The engine calls flush() as an `after` hook, once per refresh, after every
-- element renderer has added its segments.

local M = {}

-- Left-to-right order within the right column (ascending = further left).
M.SLOT = { priority = 1, cookies = 2, tags = 3 }

-- bufnr -> row -> { [slot] = chunk_list }
local pending = {}

function M.add(bufnr, row, slot, chunks)
  local rows = pending[bufnr]
  if not rows then
    rows = {}
    pending[bufnr] = rows
  end
  rows[row] = rows[row] or {}
  rows[row][slot] = chunks
end

function M.flush(bufnr, ns)
  local rows = pending[bufnr]
  if not rows then
    return
  end
  pending[bufnr] = nil
  for row, slots in pairs(rows) do
    local keys = {}
    for k in pairs(slots) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local virt = {}
    for i, k in ipairs(keys) do
      if i > 1 then
        virt[#virt + 1] = { " " }
      end
      for _, chunk in ipairs(slots[k]) do
        virt[#virt + 1] = chunk
      end
    end
    if #virt > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
        virt_text = virt,
        virt_text_pos = "right_align",
        priority = 200,
      })
    end
  end
end

-- Flush once per engine refresh, after all element renderers.
require("organ.modern.render").after(function(bufnr)
  M.flush(bufnr, require("organ.modern.render").ns)
end)

return M
