-- agenda.sorting_strategy tokens (Emacs `org-agenda-sorting-strategy`).
-- Per-block override via block.sorting_strategy.
-- Run via: nvim --headless -l tests/agenda_sorting_strategy_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local SAMPLE = {
  {
    id = "h1",
    file_path = "/work.org",
    title = "Beta",
    line_start = 1,
    level = 1,
    todo_state = "TODO",
    priority = "B",
    scheduled_date = "2026-05-04",
    tags = {},
  },
  {
    id = "h2",
    file_path = "/work.org",
    title = "Alpha",
    line_start = 2,
    level = 1,
    todo_state = "TODO",
    priority = "A",
    scheduled_date = "2026-05-04",
    tags = {},
  },
  {
    id = "h3",
    file_path = "/work.org",
    title = "Gamma",
    line_start = 3,
    level = 1,
    todo_state = "NEXT",
    priority = "C",
    scheduled_date = "2026-05-04T09:00",
    tags = {},
  },
  {
    id = "h4",
    file_path = "/work.org",
    title = "Delta",
    line_start = 4,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-04T17:00",
    tags = {},
  },
}

package.loaded["organ.query"] = {
  agenda = function()
    return SAMPLE
  end,
  headlines = function()
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
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
  -- Disable visual chrome so the test only sees the strategy order.
  agenda = { time_grid = false, now_marker = false, view_header = false },
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

local function order_in_render(strategy)
  require("organ").config.agenda.sorting_strategy = strategy
  local out = agenda.render({
    {
      block = {
        kind = "agenda",
        from = "2026-05-04",
        to = "2026-05-04",
        group_by = "day",
      },
      rows = SAMPLE,
    },
  }, { now = "2026-05-04" })
  -- Pluck title order.
  local titles = {}
  for _, l in ipairs(out.lines) do
    for _, t in ipairs({ "Alpha", "Beta", "Gamma", "Delta" }) do
      if l:find(t, 1, true) then
        titles[#titles + 1] = t
        break
      end
    end
  end
  return titles
end

-- Default time-up,priority-down,category-keep:
--   timed first (Gamma 9:00, Delta 17:00); untimed by priority-down
--   (Alpha [#A], Beta [#B]).
local def = order_in_render({ "time-up", "priority-down", "category-keep" })
check(
  "default order: Gamma → Delta → Alpha → Beta",
  def[1] == "Gamma" and def[2] == "Delta" and def[3] == "Alpha" and def[4] == "Beta",
  "got: " .. table.concat(def, ", ")
)

-- alpha-up: by title alphabetical (ignoring time / priority).
local alpha = order_in_render({ "alpha-up" })
check(
  "alpha-up: Alpha → Beta → Delta → Gamma",
  alpha[1] == "Alpha" and alpha[2] == "Beta" and alpha[3] == "Delta" and alpha[4] == "Gamma",
  "got: " .. table.concat(alpha, ", ")
)

-- priority-up: Emacs convention = lowest-importance first (none → C →
-- B → A). Delta has no priority → first; Gamma=C, Beta=B, Alpha=A.
local prio_up = order_in_render({ "priority-up" })
check(
  "priority-up: Delta → Gamma → Beta → Alpha (Emacs: lowest first)",
  prio_up[1] == "Delta" and prio_up[2] == "Gamma" and prio_up[3] == "Beta" and prio_up[4] == "Alpha",
  "got: " .. table.concat(prio_up, ", ")
)

-- priority-down: highest-importance first (A → B → C → none).
local prio_down = order_in_render({ "priority-down" })
check(
  "priority-down: Alpha → Beta → Gamma → Delta (highest first)",
  prio_down[1] == "Alpha"
    and prio_down[2] == "Beta"
    and prio_down[3] == "Gamma"
    and prio_down[4] == "Delta",
  "got: " .. table.concat(prio_down, ", ")
)

require("organ").config.agenda.sorting_strategy = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_sorting_strategy_test: PASS")
