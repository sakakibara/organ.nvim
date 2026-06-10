-- Register default highlight groups once (default = true so user/colorscheme
-- overrides win).

local M = {}

local hl_registered = false
local function register_user_faces()
  -- User-supplied per-keyword and per-tag highlights (Emacs `org-todo-
  -- keyword-faces` and `org-tag-faces`).  Re-applied on every render
  -- so config-time changes are picked up without a plugin reload.
  -- Each value can be either:
  --   * a string  -> linked highlight group name
  --   * a table   -> forwarded as the second arg to nvim_set_hl
  -- Examples:
  --   todo = { keyword_faces = { WAITING = "WarningMsg",
  --                              NEXT    = { fg = "#5fafff", bold = true } } }
  --   tags = { faces         = { urgent  = "ErrorMsg",
  --                              work    = "Type" } }
  local function apply_user_hls(prefix, tbl)
    if type(tbl) ~= "table" then
      return
    end
    for name, spec in pairs(tbl) do
      local group = prefix .. tostring(name)
      if type(spec) == "string" then
        vim.api.nvim_set_hl(0, group, { link = spec })
      elseif type(spec) == "table" then
        vim.api.nvim_set_hl(0, group, spec)
      end
    end
  end
  local org = require("organ")
  if org.config and org.config.todo and org.config.todo.keyword_faces then
    local lower = {}
    for k, v in pairs(org.config.todo.keyword_faces) do
      lower[k:lower()] = v
    end
    apply_user_hls("@organ.agenda.todo_", lower)
  end
  if org.config and org.config.tags and org.config.tags.faces then
    apply_user_hls("@organ.agenda.tag_", org.config.tags.faces)
  end
end

function M.register()
  -- User faces always re-apply (cheap; lets config-time tweaks take
  -- effect on the next render without a plugin reload).
  register_user_faces()
  if hl_registered then
    return
  end
  hl_registered = true
  local hls = {
    ["@organ.agenda.header"] = "Title",
    ["@organ.agenda.date_today"] = "Constant",
    ["@organ.agenda.date_overdue"] = "ErrorMsg",
    ["@organ.agenda.todo_todo"] = "WarningMsg",
    ["@organ.agenda.todo_next"] = "Statement",
    ["@organ.agenda.todo_done"] = "Comment",
    ["@organ.agenda.priority_A"] = "ErrorMsg",
    ["@organ.agenda.priority_B"] = "WarningMsg",
    ["@organ.agenda.priority_C"] = "Comment",
    ["@organ.agenda.tag"] = "Type",
    -- Single-cell overflow marker emitted in place of the full tag
    -- block when the row would not fit in the window's content area.
    -- Linked to NonText so it's visually subdued (matches Emacs's
    -- continuation-marker convention).
    ["@organ.agenda.tag_overflow"] = "NonText",
    ["@organ.agenda.category"] = "Identifier",
    ["@organ.agenda.location"] = "Directory",
    ["@organ.agenda.block_separator"] = "NonText",
    ["@organ.agenda.time"] = "Number",
    ["@organ.agenda.effort"] = "Number",
    ["@organ.agenda.block_header"] = "Title",
    -- Title text (per-row title bytes). Distinct from @organ.agenda.header
    -- (which is the date / block heading line).
    ["@organ.agenda.view_header"] = "Title",
    ["@organ.agenda.title"] = "Function",
    -- Emacs `org-scheduled` / `org-upcoming-deadline` faces; these
    -- color the "Scheduled:" / "Deadline:" tag text in row prefixes.
    ["@organ.agenda.scheduled"] = "Function",
    ["@organ.agenda.deadline"] = "WarningMsg",
    -- "<- now" marker line in today's group_by="day" bucket.
    ["@organ.agenda.now_marker"] = "Special",
    -- Body-preview lines injected by entry-text mode (org-agenda-
    -- entry-text-mode).
    ["@organ.agenda.entry_text"] = "Comment",
  }
  for group, link in pairs(hls) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

return M
