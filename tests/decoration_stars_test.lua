-- Unit test for the stars provider via organ.decoration.
--
-- Verifies that loading organ.stars registers a decoration provider,
-- the per-buffer row cache is built from on_lines, and the on_line
-- dispatcher emits one conceal-space extmark per leading-star byte
-- (N-1 marks for a level-N headline).  Ephemeral marks placed by
-- on_line aren't visible to nvim_buf_get_extmarks outside the real
-- frame-rendering context, so the assertions go through _apply, which
-- shares build_cache with on_lines but writes non-ephemeral marks.
--
-- Run via: nvim --headless -l tests/decoration_stars_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  stars = { hide = true },
})
-- Loading the module triggers its top-level decoration.register({...}).
require("organ.stars")

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local providers, _ = decoration._providers()
check("stars provider registered", providers.stars ~= nil)
check("provider exposes ns", providers.stars and providers.stars.ns ~= nil)
check(
  "provider exposes on_lines + on_line",
  providers.stars
    and type(providers.stars.on_lines) == "function"
    and type(providers.stars.on_line) == "function"
)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Top",
  "** Sub",
  "*** Deep",
  "not a heading",
})

decoration.attach(bufnr)

local winid = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(winid, bufnr)
vim.wo[winid].conceallevel = 2

-- _apply rebuilds the cache + writes non-ephemeral marks so
-- nvim_buf_get_extmarks can see them.  The ephemeral path is exercised
-- by the real decoration-provider callback at frame time.
require("organ.stars")._apply(bufnr)

local NS = vim.api.nvim_create_namespace("organ_stars_hide")
local top = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 0, 0 }, { 0, -1 }, { details = true })
local sub = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 1, 0 }, { 1, -1 }, { details = true })
local deep = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 2, 0 }, { 2, -1 }, { details = true })
local plain = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 3, 0 }, { 3, -1 }, { details = true })

check("level-1 headline has NO conceal mark (1 star always shown)", #top == 0)
check("level-2 headline has 1 conceal mark", #sub == 1)
check(
  "level-3 headline has 2 conceal marks (N-1 = 2)",
  #deep == 2,
  "got " .. #deep .. ": " .. vim.inspect(deep)
)
check("non-headline line has no mark", #plain == 0)

-- Every mark replaces one byte with " ".
local all_conceal_space = true
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
  if m[4].conceal ~= " " then
    all_conceal_space = false
    break
  end
end
check('every mark has conceal=" "', all_conceal_space)

vim.api.nvim_buf_delete(bufnr, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_stars_test: PASS")
os.exit(0)
