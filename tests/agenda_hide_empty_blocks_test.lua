-- agenda.hide_empty_blocks: blocks with zero rows are skipped during
-- multi-block render. Mirrors Emacs `org-agenda-hide-empty-blocks`.
-- Run via: nvim --headless -l tests/agenda_hide_empty_blocks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local SAMPLE = {
  {
    id = "h1",
    file_path = "/work.org",
    title = "Active task",
    line_start = 1,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-04",
    tags = {},
  },
}

package.loaded["organ.query"] = {
  agenda = function(opts)
    -- The "Empty" block filters everything out via title_match.
    if opts and opts.title_match == "ZZZNONE" then
      return {}
    end
    return SAMPLE
  end,
  headlines = function(opts)
    if opts and opts.title_match == "ZZZNONE" then
      return {}
    end
    return SAMPLE
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function render_view()
  return agenda.render({
    {
      block = {
        label = "Has Rows",
        from = "2026-05-04",
        to = "2026-05-04",
        group_by = "none",
      },
      rows = SAMPLE,
    },
    {
      block = {
        label = "Empty",
        from = "2026-05-04",
        to = "2026-05-04",
        group_by = "none",
        title_match = "ZZZNONE",
      },
      rows = {},
    },
  }, { now = "2026-05-04" })
end

-- Default (hide_empty_blocks = false) shows BOTH block headers.
require("organ").config.agenda.hide_empty_blocks = false
local out_default = render_view()
local body_default = table.concat(out_default.lines, "\n")
check("default: 'Has Rows' header present", body_default:find("Has Rows", 1, true) ~= nil)
check("default: 'Empty' header present", body_default:find("Empty", 1, true) ~= nil)

-- With hide_empty_blocks = true, the empty block is skipped entirely.
require("organ").config.agenda.hide_empty_blocks = true
local out_hidden = render_view()
local body_hidden = table.concat(out_hidden.lines, "\n")
check("hidden: 'Has Rows' header still present", body_hidden:find("Has Rows", 1, true) ~= nil)
check(
  "hidden: 'Empty' header SUPPRESSED",
  body_hidden:find("Empty", 1, true) == nil,
  "got body:\n" .. body_hidden
)

require("organ").config.agenda.hide_empty_blocks = false -- reset

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_hide_empty_blocks_test: PASS")
