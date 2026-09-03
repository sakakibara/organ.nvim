-- Every render-engine element shares one engine per buffer (augroup,
-- debounce timer, namespace, raised conceallevel).  Toggling ONE
-- element off must leave the engine running for the elements still
-- enabled; only the last element to go tears it down.
--
-- Run via: nvim --headless -l tests/modern_element_toggle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = { bullets = true, pills = true },
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

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "* TODO one", "** two", "body" }, dir .. "/a.org")
vim.cmd("edit " .. dir .. "/a.org")
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
vim.wait(100)
local bufnr = vim.api.nvim_get_current_buf()
local render = require("organ.modern.render")
local buf_config = require("organ.buf_config")

local function count()
  return #vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, {})
end
local function augroup_alive()
  return pcall(vim.api.nvim_get_autocmds, { group = "organ_modern_render_" .. bufnr })
end

vim.cmd("redraw")
render._render_now(bufnr)
check("bullets + pills render marks", count() > 0, "got " .. count())
check("engine augroup alive", augroup_alive())
check("engine raised conceallevel", vim.wo.conceallevel == 2, "got " .. vim.wo.conceallevel)

buf_config.toggle(bufnr, "modern.pills")
vim.wait(100)
check("bullets still enabled", buf_config.read(bufnr, "modern.bullets") == true)
check("engine augroup survives toggling pills off", augroup_alive())
check("bullet marks remain after toggling pills off", count() > 0, "got " .. count())
check("conceallevel still raised", vim.wo.conceallevel == 2, "got " .. vim.wo.conceallevel)

vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "*** three" })
vim.cmd("doautocmd TextChanged")
vim.wait(200)
check("engine still refreshes on edit", count() > 0, "got " .. count())

buf_config.toggle(bufnr, "modern.bullets")
vim.wait(100)
check("engine augroup torn down once no element is left", not augroup_alive())
check("no engine marks after the last element goes", count() == 0, "got " .. count())
check("conceallevel restored", vim.wo.conceallevel == 0, "got " .. vim.wo.conceallevel)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_element_toggle_test: PASS")
os.exit(0)
