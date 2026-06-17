-- Shared construction of an org-roam-style file node header, used by both
-- `organ.roam` (nodes) and `organ.roam.dailies`.  Keeps the two in lock-step
-- with each other and with what Emacs org-roam writes.

local M = {}

-- File-level node header: the :ID: property drawer followed by #+title.
-- The 7 spaces after `:ID:` reproduce Emacs `org-property-format`
-- ("%-10s %s") applied to the `:ID:` key (4 cols padded to 10, then one
-- space).
function M.header(id, title)
  return {
    ":PROPERTIES:",
    ":ID:       " .. id,
    ":END:",
    "#+title: " .. title,
  }
end

return M
