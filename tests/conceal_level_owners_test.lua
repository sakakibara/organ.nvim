-- Several features need `conceallevel >= 2` and each switches off on its
-- own, so the window's own value is saved once and restored when the last
-- of them lets go.  Turning every feature off must land on the value the
-- window had before organ touched it -- the same value `:Org conceal
-- toggle` off lands on.
-- Run via: nvim --headless -l tests/conceal_level_owners_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/a.org"
vim.fn.writefile({
  "* TODO [#A] Head :tag:",
  "  DEADLINE: <2026-09-05 Sat>",
  "- [ ] item",
  "*bold* /it/ \\alpha",
}, path)

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = "all",
  indent = { enabled = true },
  stars = { hide = true },
  entities = { enabled = true },
  emphasis = { enabled = true },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local FLAGS = {
  "emphasis.enabled",
  "stars.hide",
  "entities.enabled",
  "modern.bullets",
  "modern.checkboxes",
  "modern.dates",
  "modern.tags",
  "modern.priority",
  "modern.blocks",
  "modern.drawers",
  "modern.directives",
  "modern.cookies",
  "modern.pills",
  "modern.rule",
  "modern.list_bullets",
  "modern.table",
}

vim.cmd("edit " .. path)
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
vim.wait(120)
local b = vim.api.nvim_get_current_buf()
local buf_config = require("organ.buf_config")

check("window starts concealing", vim.wo.conceallevel == 2, "got " .. vim.wo.conceallevel)

local function set_all(value)
  for _, f in ipairs(FLAGS) do
    buf_config.set(b, f, value)
  end
  vim.wait(150)
end

set_all(false)
check(
  "conceallevel back to 0 once every feature is off",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

set_all(true)
check("conceallevel raised again", vim.wo.conceallevel == 2, "got " .. vim.wo.conceallevel)

set_all(false)
check(
  "conceallevel back to 0 on the second round",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

-- `:Org conceal toggle` lands on the same resting value, and while another
-- consumer still holds the level it leaves the window alone.
local conceal = require("organ.conceal")
check("toggle on raises", conceal.toggle(b) == true and vim.wo.conceallevel == 2)
check("toggle off restores", conceal.toggle(b) == false and vim.wo.conceallevel == 0)

buf_config.set(b, "modern.bullets", true)
vim.wait(150)
check("modern alone raises", vim.wo.conceallevel == 2, "got " .. vim.wo.conceallevel)
conceal.toggle(b)
check("toggle on while modern holds", vim.wo.conceallevel == 2, "got " .. vim.wo.conceallevel)
conceal.toggle(b)
check(
  "toggle off does not drop the level modern still needs",
  vim.wo.conceallevel == 2,
  "got " .. vim.wo.conceallevel
)
buf_config.set(b, "modern.bullets", false)
vim.wait(150)
check(
  "the last consumer letting go restores 0",
  vim.wo.conceallevel == 0,
  "got " .. vim.wo.conceallevel
)

check("global conceallevel never written", vim.go.conceallevel == 0, "got " .. vim.go.conceallevel)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
io.write("conceal_level_owners ok\n")
os.exit(0)
