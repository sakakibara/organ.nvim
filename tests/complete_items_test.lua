-- complete.items_for(kind, query) returns items[] per the spec table.
-- Run via: nvim --headless -l tests/complete_items_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([=[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
  body

* Beta
  Body line, no ID.
]=])
fh:close()

local att = tmp .. "/att"
vim.fn.mkdir(att, "p")
io.open(att .. "/note.png", "w"):close()
io.open(att .. "/draft.pdf", "w"):close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  complete = { attachment_dir = att, file_walk_max_results = 50 },
})
require("organ").scan_blocking(org_dir, 5000)

local complete = require("organ.complete")

-- id source: only headlines with :ID: → Alpha
local id_items = complete.items_for("id", "")
assert(#id_items == 1, "id: expected 1 item, got " .. #id_items)
assert(id_items[1].insert_text == "alpha-id")
assert(id_items[1].description == "Alpha")
assert(id_items[1].kind == "id")
assert(id_items[1].display:find("Alpha", 1, true), "display: " .. id_items[1].display)

-- headline source: all headlines → Alpha + Beta
local hl_items = complete.items_for("headline", "")
assert(#hl_items == 2, "headline: expected 2 items, got " .. #hl_items)
local titles = {}
for _, it in ipairs(hl_items) do
  titles[it.insert_text] = true
end
assert(titles["Alpha"] and titles["Beta"], "expected Alpha + Beta titles")

-- attachment source: lists files in attachment_dir
local att_items = complete.items_for("attachment", "")
assert(#att_items == 2, "attachment: expected 2 items, got " .. #att_items)
local names = {}
for _, it in ipairs(att_items) do
  names[it.insert_text] = true
end
assert(names["note.png"] and names["draft.pdf"], "expected both attachments")

-- attachment with substring filter
local png_only = complete.items_for("attachment", "note")
assert(#png_only == 1, "attachment substring: expected 1, got " .. #png_only)
assert(png_only[1].insert_text == "note.png")

-- file source: walks cwd; verify cap respected.
local files = complete.items_for("file", "")
assert(#files > 0 and #files <= 50, "file: expected (0, 50], got " .. #files)

-- file substring filter
local lua_files = complete.items_for("file", ".lua")
for _, it in ipairs(lua_files) do
  assert(it.insert_text:find(".lua", 1, true), "file substring filter: " .. it.insert_text)
end

-- attachment_dir doesn't exist → empty
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  complete = { attachment_dir = tmp .. "/missing" },
})
local empty = complete.items_for("attachment", "")
assert(#empty == 0, "missing attachment_dir: expected 0, got " .. #empty)

vim.fn.delete(tmp, "rf")
io.write("complete items ok\n")
os.exit(0)
