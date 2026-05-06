-- E2E: refile a heading from one file to another, re-index, both files'
-- contents reflected in the DB. Catches the bug class where refile mutates
-- on disk but the indexer doesn't pick up either side, so subsequent
-- queries / agenda / backlinks point to stale data.
--
-- Run via: nvim --headless -l tests/refile_to_index_e2e_test.lua

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

local parser_path = original_stdpath("data") .. "/organ/parser/org.so"
if vim.fn.filereadable(parser_path) ~= 1 then
  io.write("(skipped: parser not installed)\nrefile_to_index_e2e_test: SKIP\n")
  vim.fn.stdpath = original_stdpath
  vim.fn.delete(tmp, "rf")
  os.exit(0)
end

local src_path = org_dir .. "/src.org"
local tgt_path = org_dir .. "/tgt.org"
do
  local f = assert(io.open(src_path, "w"))
  f:write([[* Alpha
  body of alpha
** Alpha child
   nested body
* Sibling
  sibling body
]])
  f:close()
  f = assert(io.open(tgt_path, "w"))
  f:write("* Target\n  target body\n")
  f:close()
end

require("organ").setup({
  db_path = tmp .. "/r.db",
  org_dir = org_dir,
  parser_path = parser_path,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  mtime_skip = false,
  hash_skip = false,
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

local query = require("organ.query")

-- Sanity: pre-refile, both Alpha and Target are indexed.
local pre_alpha, pre_target
for _, r in ipairs(query.headlines()) do
  if r.title == "Alpha" then
    pre_alpha = r
  end
  if r.title == "Target" then
    pre_target = r
  end
end
check(
  "pre-refile: Alpha is indexed under src.org",
  pre_alpha and pre_alpha.file_path == src_path,
  "got " .. vim.inspect(pre_alpha and pre_alpha.file_path)
)
check(
  "pre-refile: Target is indexed under tgt.org",
  pre_target and pre_target.file_path == tgt_path
)

-- Perform the refile (Alpha + its child subtree → under Target).
local refile = require("organ.refile")
local sb = vim.fn.bufadd(src_path)
vim.fn.bufload(sb)
local err = refile.move(sb, 1, tgt_path, 1)
check("refile: returns no error", err == nil, "err: " .. tostring(err))

-- Save both buffers explicitly via their bufnrs (cmd "write" uses current
-- buffer's name, which can be empty when we set_current_buf to a hidden buf).
vim.api.nvim_buf_call(sb, function()
  vim.cmd("write")
end)
local tb = vim.fn.bufadd(tgt_path)
vim.fn.bufload(tb)
vim.api.nvim_buf_call(tb, function()
  vim.cmd("write")
end)

-- Re-index both files.
require("organ").scan_blocking(org_dir, 5000)

-- Now query: Alpha lives in tgt.org, NOT src.org.
local post_alpha, post_alpha_child, post_sibling
for _, r in ipairs(query.headlines()) do
  if r.title == "Alpha" then
    post_alpha = r
  end
  if r.title == "Alpha child" then
    post_alpha_child = r
  end
  if r.title == "Sibling" then
    post_sibling = r
  end
end
check(
  "post-refile: Alpha is indexed under tgt.org",
  post_alpha and post_alpha.file_path == tgt_path,
  "got " .. vim.inspect(post_alpha and post_alpha.file_path)
)
check(
  "post-refile: Alpha child also moved (subtree refile)",
  post_alpha_child and post_alpha_child.file_path == tgt_path
)
check("post-refile: Sibling stayed in src.org", post_sibling and post_sibling.file_path == src_path)

-- And src.org no longer has Alpha.
local src_still_has_alpha = false
for _, r in ipairs(query.headlines()) do
  if r.title == "Alpha" and r.file_path == src_path then
    src_still_has_alpha = true
  end
end
check("post-refile: Alpha is gone from src.org index", not src_still_has_alpha)

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("refile_to_index_e2e_test: PASS")
