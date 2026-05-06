-- `todo.keyword_faces` and `tags.faces` are per-state / per-tag
-- highlight overrides (Emacs `org-todo-keyword-faces` and `org-tag-
-- faces`).  Each value is a highlight group name OR an nvim_set_hl
-- opts table.  Drives:
--   * agenda TODO column → `@organ.agenda.todo_<state>` linked
--   * agenda tag block   → per-tag chunks with `@organ.agenda.tag_<tag>`
--
-- Run via: nvim --headless -l tests/agenda_faces_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local SAMPLE = {
  {
    id = "h1",
    file_path = "/x.org",
    title = "Tagged row",
    todo_state = "WAITING",
    priority = "B",
    line_start = 1,
    level = 1,
    scheduled_date = "2026-05-04",
    tags = { "urgent", "work" },
    n_direct_tags = 2,
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
  get_by_id = function()
    return nil
  end,
  parse_date = function(s)
    return s
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = {
    sequence = { "TODO", "WAITING", "|", "DONE" },
    keyword_faces = {
      WAITING = "WarningMsg",
    },
  },
  tags = {
    faces = {
      urgent = "ErrorMsg",
      work = { fg = "#5fafff", bold = true },
    },
  },
})

local agenda = require("organ.agenda")

-- (a) keyword_faces: hl group is registered + linked.
local hl_waiting = vim.api.nvim_get_hl(0, { name = "@organ.agenda.todo_waiting" })
check(
  "todo.keyword_faces: @organ.agenda.todo_waiting linked",
  hl_waiting.link == "WarningMsg" or hl_waiting.fg ~= nil,
  vim.inspect(hl_waiting)
)

-- (b) tags.faces: per-tag hl groups registered.
local hl_urg = vim.api.nvim_get_hl(0, { name = "@organ.agenda.tag_urgent" })
check("tags.faces: @organ.agenda.tag_urgent linked to ErrorMsg", hl_urg.link == "ErrorMsg")
local hl_work = vim.api.nvim_get_hl(0, { name = "@organ.agenda.tag_work" })
check(
  "tags.faces: @organ.agenda.tag_work has fg color",
  hl_work.fg ~= nil and hl_work.bold == true,
  vim.inspect(hl_work)
)

-- (c) Per-tag chunks emitted in virt_text.
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.tags_virt_align = true
local out_v = agenda.render({
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
local saw_urgent_chunk = false
local saw_work_chunk = false
for _, mk in ipairs(out_v.extmarks) do
  if mk[2] == "_virt" and type(mk[5]) == "table" and mk[5].virt_text then
    for _, chunk in ipairs(mk[5].virt_text) do
      if chunk[1] == "urgent" and chunk[2] == "@organ.agenda.tag_urgent" then
        saw_urgent_chunk = true
      end
      if chunk[1] == "work" and chunk[2] == "@organ.agenda.tag_work" then
        saw_work_chunk = true
      end
    end
  end
end
check("virt_text: per-tag `urgent` chunk uses tag_urgent hl group", saw_urgent_chunk)
check("virt_text: per-tag `work` chunk uses tag_work hl group", saw_work_chunk)

-- (d) Inline path: per-tag extmarks with the tag-specific hl group.
require("organ").config.agenda.tags_virt_align = false
local out_i = agenda.render({
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
local urgent_mark, work_mark = false, false
for _, mk in ipairs(out_i.extmarks) do
  if mk[2] == "@organ.agenda.tag_urgent" then
    urgent_mark = true
  end
  if mk[2] == "@organ.agenda.tag_work" then
    work_mark = true
  end
end
check("inline: extmark with @organ.agenda.tag_urgent emitted", urgent_mark)
check("inline: extmark with @organ.agenda.tag_work emitted", work_mark)

require("organ").config.agenda.tags_virt_align = nil

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_faces_test: PASS")
