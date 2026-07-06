-- highlights.register() and register_todo_keywords() install default links
-- with default = true so colorscheme/user definitions win.
-- Run via: nvim --headless -l tests/highlights_register_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local hl = require("organ.highlights")

-- Pre-populate one user override to verify default = true respects it.
vim.api.nvim_set_hl(0, "@org.heading.1", { fg = "#ff0000" }) -- user value

hl.register()

local h1 = vim.api.nvim_get_hl(0, { name = "@org.heading.1" })
-- User's #ff0000 (16711680) must survive because we passed default = true.
assert(h1.fg == 16711680, "user @org.heading.1 fg should be preserved; got " .. vim.inspect(h1))

-- @org.heading.2 had no user override → our default link applies.
-- Progressive enhancement: prefer `@markup.heading.2.markdown`
-- when the colorscheme styles it, else fall back to `Function` (a
-- core vim group every colorscheme defines).  Either is acceptable.
local h2 = vim.api.nvim_get_hl(0, { name = "@org.heading.2" })
assert(
  h2.link == "Function" or h2.link == "@markup.heading.2.markdown",
  "@org.heading.2 should link to Function or @markup.heading.2.markdown; got " .. vim.inspect(h2)
)

-- @org.priority static link.
local prio = vim.api.nvim_get_hl(0, { name = "@org.priority" })
assert(prio.link == "Special", "got " .. vim.inspect(prio))

-- TODO keyword registration links each keyword to its semantic bucket:
-- TODO -> actionable, DONE -> done, CANCELLED -> cancelled.
hl.register_todo_keywords({ "TODO", "NEXT", "|", "DONE", "CANCELLED" })
local todo = vim.api.nvim_get_hl(0, { name = "@org.todo.todo" })
assert(todo.link == hl.todo_bucket_link("actionable"), "got " .. vim.inspect(todo))
local done = vim.api.nvim_get_hl(0, { name = "@org.todo.done" })
assert(done.link == hl.todo_bucket_link("done"), "got " .. vim.inspect(done))
local cancelled = vim.api.nvim_get_hl(0, { name = "@org.todo.cancelled" })
assert(cancelled.link == hl.todo_bucket_link("cancelled"), "got " .. vim.inspect(cancelled))

io.write("highlights register ok\n")
os.exit(0)
