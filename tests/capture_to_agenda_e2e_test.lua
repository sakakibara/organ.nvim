-- E2E: capture → file appended → indexer picks up → agenda lists it →
-- toggle TODO via agenda → source file updated → re-indexed agenda
-- reflects new state.
--
-- This is the daily user loop. Each module tested in isolation elsewhere;
-- this test pins the interaction so a regression in any one of them
-- (capture format, indexer triggers, agenda render, todo cycle write-back)
-- shows up here.
--
-- Run via: nvim --headless -l tests/capture_to_agenda_e2e_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(w)
  if w == "data" then
    return data_dir
  end
  return original_stdpath(w)
end

local target_path = vim.fn.resolve(org_dir .. "/inbox.org")
do
  local f = assert(io.open(target_path, "w"))
  f:write("* Existing entry\n  has body\n")
  f:close()
end

local parser_path = original_stdpath("data") .. "/organ/parser/org.so"
if vim.fn.filereadable(parser_path) ~= 1 then
  io.write("(skipped: org tree-sitter parser not installed at " .. parser_path .. ")\n")
  io.write("capture_to_agenda_e2e_test: SKIP\n")
  vim.fn.stdpath = original_stdpath
  vim.fn.delete(tmp, "rf")
  os.exit(0)
end

require("organ").setup({
  db_path = tmp .. "/e.db",
  org_dir = org_dir,
  parser_path = parser_path,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  mtime_skip = false,
  hash_skip = false,
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})
require("organ").scan_blocking(org_dir, 5000)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- 1. Capture: start with a programmatic template, finalize, file appended.
-- ---------------------------------------------------------------------------
local capture = require("organ.capture")

do
  local template = {
    name = "Inbox",
    target = { kind = "file", path = target_path },
    body = "* TODO %?\n  captured body",
  }
  local ctx = {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    cword = "",
    visual_text = "",
    prompts = { text = {}, dates = {} },
    now = os.time(),
  }
  capture.start(template, ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  -- Type the title in (the first line is "* TODO " with cursor right after).
  vim.api.nvim_buf_set_text(bufnr, 0, #"* TODO ", 0, #"* TODO ", { "Buy milk" })
  capture.finalise(bufnr)
end

-- File should have grown with our new entry.
local lines_after_capture = vim.fn.readfile(target_path)
local new_heading_idx
for i, l in ipairs(lines_after_capture) do
  if l == "* TODO Buy milk" then
    new_heading_idx = i
    break
  end
end
check(
  "capture: new heading appended to target file",
  new_heading_idx ~= nil,
  "file contents:\n" .. table.concat(lines_after_capture, "\n")
)
check(
  "capture: body line follows the heading",
  new_heading_idx and lines_after_capture[new_heading_idx + 1] == "  captured body"
)

-- ---------------------------------------------------------------------------
-- 2. Indexer picks up the change → query.headlines includes it.
-- capture.finalise writes via low-level file ops; without the watcher the
-- file change isn't auto-enqueued. Re-walk the org_dir explicitly.
-- ---------------------------------------------------------------------------
require("organ").scan_blocking(org_dir, 5000)

local query = require("organ.query")
local found_in_index
do
  local rows = query.headlines({ todo = { "TODO" } })
  for _, r in ipairs(rows) do
    if r.title == "Buy milk" then
      found_in_index = r
      break
    end
  end
end
check(
  "indexer: query.headlines returns the new heading",
  found_in_index ~= nil,
  "indexed rows: " .. (found_in_index and "(found)" or "(not found)")
)
check("indexer: stored todo_state is TODO", found_in_index and found_in_index.todo_state == "TODO")

-- ---------------------------------------------------------------------------
-- 3. Agenda lists the new heading.
-- ---------------------------------------------------------------------------
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.views = require("organ").config.agenda.views or {}
require("organ").config.agenda.views.t = {
  blocks = {
    {
      source = "headlines",
      title = "All TODOs",
      query = { todo = { "TODO" } },
      line_format = "{title} [{todo_state}]",
    },
  },
}

local agenda = require("organ.agenda")
agenda.open({ name = "t" })
local agenda_buf = vim.api.nvim_get_current_buf()
local agenda_lines = vim.api.nvim_buf_get_lines(agenda_buf, 0, -1, false)

local agenda_has_new
local agenda_lnum
for i, l in ipairs(agenda_lines) do
  if l:find("Buy milk", 1, true) then
    agenda_has_new = true
    agenda_lnum = i
    break
  end
end
check(
  "agenda: rendered line includes new heading",
  agenda_has_new,
  "agenda lines:\n" .. table.concat(agenda_lines, "\n")
)

-- ---------------------------------------------------------------------------
-- 4. Toggle TODO via agenda — `t` keymap → state cycles → file writes back
-- ---------------------------------------------------------------------------
do
  vim.api.nvim_win_set_cursor(0, { agenda_lnum, 0 })
  -- Trigger the `t` mapping via feedkeys.
  vim.api.nvim_feedkeys("t", "x", false)
  vim.wait(200)
end

-- File should now have NEXT instead of TODO for "Buy milk".
local lines_after_toggle = vim.fn.readfile(target_path)
local toggled_heading
for _, l in ipairs(lines_after_toggle) do
  if l:match("^%*%s+%S+%s+Buy milk$") then
    toggled_heading = l
    break
  end
end
check(
  "toggle: file updated with new TODO state for Buy milk",
  toggled_heading and toggled_heading == "* NEXT Buy milk",
  "got " .. tostring(toggled_heading)
)

-- ---------------------------------------------------------------------------
-- 5. Re-index → agenda re-render → reflects new state.
-- ---------------------------------------------------------------------------
require("organ").scan_blocking(org_dir, 5000)
agenda.refresh(agenda_buf)
local agenda_lines2 = vim.api.nvim_buf_get_lines(agenda_buf, 0, -1, false)
local has_next
for _, l in ipairs(agenda_lines2) do
  if l:find("Buy milk", 1, true) and l:find("NEXT", 1, true) then
    has_next = true
    break
  end
end
-- The new agenda view filters by todo={TODO} so the toggled line should
-- DISAPPEAR (NEXT no longer matches the query). Either way works as proof
-- of refresh having happened. We accept both: line gone OR line shows NEXT.
local has_buy_milk_at_all
for _, l in ipairs(agenda_lines2) do
  if l:find("Buy milk", 1, true) then
    has_buy_milk_at_all = true
    break
  end
end
check(
  "agenda re-render: filtered out (TODO query) OR shows NEXT",
  (not has_buy_milk_at_all) or has_next,
  "agenda lines:\n" .. table.concat(agenda_lines2, "\n")
)

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("capture_to_agenda_e2e_test: PASS")
