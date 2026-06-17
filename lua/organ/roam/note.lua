-- Shared construction of an org-roam-style file node header, used by both
-- `organ.roam` (nodes) and `organ.roam.dailies`.  Keeps the two in lock-step
-- with each other and with what Emacs org-roam writes.

local M = {}

-- File-level node header: the :ID: property drawer followed by #+title.
-- The :ID: line is formatted through the shared property formatter so its
-- org-property-format alignment matches every other :ID: organ writes.
function M.header(id, title)
  return {
    ":PROPERTIES:",
    require("organ.property").format_line("ID", id),
    ":END:",
    "#+title: " .. title,
  }
end

return M
