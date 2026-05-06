-- publish.publish: walks base_directory, exports each .org via the configured
-- backend, writes to publishing_directory preserving relative path; honors
-- exclude pattern; with_sitemap emits a sitemap file.
-- Run via: nvim --headless -l tests/publish_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local base = tmp .. "/in"
local out = tmp .. "/out"
vim.fn.mkdir(base, "p")
vim.fn.mkdir(out, "p")
vim.fn.mkdir(base .. "/sub", "p")
vim.fn.mkdir(base .. "/draft", "p")

local function write(path, body)
  local fd = assert(io.open(path, "w"))
  fd:write(body)
  fd:close()
end
write(base .. "/index.org", "* Index\nbody one\n")
write(base .. "/sub/post.org", "* Post\nbody two\n")
write(base .. "/draft/wip.org", "* WIP\nbody three\n")

require("organ").setup({
  db_path = tmp .. "/x.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  publish = {
    projects = {
      site = {
        base_directory = base,
        publishing_directory = out,
        publishing_function = "markdown",
        recursive = true,
        exclude = "draft/",
        with_sitemap = true,
      },
    },
  },
})

local pub = require("organ.publish")
local result = pub.publish("site")
assert(result, "publish returned nil")
assert(result.ok == 2, "expected 2 ok files (index + post; draft excluded); got " .. result.ok)
assert(#result.errors == 0, "errors: " .. vim.inspect(result.errors))

-- Verify outputs exist with expected extension.
assert(vim.uv.fs_stat(out .. "/index.md"), "index.md missing")
assert(vim.uv.fs_stat(out .. "/sub/post.md"), "sub/post.md missing")
assert(not vim.uv.fs_stat(out .. "/draft/wip.md"), "draft/ should have been excluded")

-- Sitemap was written and rendered.
assert(vim.uv.fs_stat(out .. "/sitemap.org"), "sitemap.org missing")
assert(vim.uv.fs_stat(out .. "/sitemap.md"), "sitemap.md missing")

-- Sitemap content includes both published files.
local fd = assert(io.open(out .. "/sitemap.md", "r"))
local body = fd:read("*a")
fd:close()
assert(body:find("index.org", 1, true), "sitemap should mention index.org")
assert(body:find("sub/post.org", 1, true), "sitemap should mention sub/post.org")
assert(not body:find("draft/wip", 1, true), "sitemap should not mention excluded files")

-- list_projects returns configured names.
local names = pub.list_projects()
assert(#names == 1 and names[1] == "site", "list_projects: " .. vim.inspect(names))

vim.fn.delete(tmp, "rf")
io.write("publish ok\n")
os.exit(0)
