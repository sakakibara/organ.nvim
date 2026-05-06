-- refile.move(src_bufnr, src_line, target_file, target_line)
-- Run via: nvim --headless -l tests/refile_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local refile = require("organ.refile")

local function read_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function write_buf(text)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n"))
  return b
end

-- 1. Cross-file refile, subtree (headline + body + nested headline).
do
  local src = write_buf([[* Alpha
  body of alpha
** Alpha child
   nested body
* Sibling
  sibling body]])
  local tgt = write_buf([[* Target
  target body]])
  local err = refile.move(src, 1, vim.fn.tempname(), 1)
  -- Hold on: target_file can't be the in-memory tgt. The function uses
  -- bufadd(target_file). For testing we pass a real path that already exists
  -- on disk. Fall through to the file-based test below.
  -- Skip this in-memory case; we exercise refile end-to-end via files.
end

-- 2. End-to-end: write two files, refile from one to the other, verify both.
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local src_path = tmp .. "/src.org"
  local tgt_path = tmp .. "/tgt.org"
  local src_text = [[* Alpha
  body of alpha
** Alpha child
   nested body
* Sibling
  sibling body
]]
  local tgt_text = [[* Target
  target body
]]
  local fh = assert(io.open(src_path, "w"))
  fh:write(src_text)
  fh:close()
  fh = assert(io.open(tgt_path, "w"))
  fh:write(tgt_text)
  fh:close()

  local sb = vim.fn.bufadd(src_path)
  vim.fn.bufload(sb)
  local err = refile.move(sb, 1, tgt_path, 1)
  assert(err == nil, "refile err: " .. tostring(err))

  local src_after = read_lines(sb)
  -- Alpha + its body + nested headline + nested body all gone; Sibling remains.
  assert(
    src_after[1] == "* Sibling",
    "expected first src line = '* Sibling', got '" .. (src_after[1] or "") .. "'"
  )

  local tb = vim.fn.bufadd(tgt_path)
  vim.fn.bufload(tb)
  local tgt_after = read_lines(tb)
  -- Target headline at level 1; Alpha refiled as ** Alpha (level 2).
  assert(tgt_after[1] == "* Target")
  assert(
    tgt_after[2] == "** Alpha",
    "expected '** Alpha' as first child, got '" .. (tgt_after[2] or "") .. "'"
  )
  -- Alpha child shifts from ** to *** since delta = +1.
  local has_alpha_child = false
  for _, ln in ipairs(tgt_after) do
    if ln == "*** Alpha child" then
      has_alpha_child = true
      break
    end
  end
  assert(
    has_alpha_child,
    "expected '*** Alpha child' after refile; got:\n" .. table.concat(tgt_after, "\n")
  )

  vim.fn.delete(tmp, "rf")
end

-- 3. Error: target line is not a headline.
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local src_path = tmp .. "/src.org"
  local tgt_path = tmp .. "/tgt.org"
  local fh = assert(io.open(src_path, "w"))
  fh:write("* X\n")
  fh:close()
  fh = assert(io.open(tgt_path, "w"))
  fh:write("just text\nmore text\n")
  fh:close()
  local sb = vim.fn.bufadd(src_path)
  vim.fn.bufload(sb)
  local err = refile.move(sb, 1, tgt_path, 1)
  assert(
    err and err:find("target line is not a headline"),
    "expected target-not-headline error, got: " .. tostring(err)
  )
  vim.fn.delete(tmp, "rf")
end

-- 4. Cursor on body text walks up to nearest parent headline.
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local src_path = tmp .. "/src.org"
  local tgt_path = tmp .. "/tgt.org"
  local fh = assert(io.open(src_path, "w"))
  fh:write("* Alpha\n  body line 1\n  body line 2\n")
  fh:close()
  fh = assert(io.open(tgt_path, "w"))
  fh:write("* Target\n")
  fh:close()
  local sb = vim.fn.bufadd(src_path)
  vim.fn.bufload(sb)
  local err = refile.move(sb, 3, tgt_path, 1) -- cursor on "body line 2"
  assert(err == nil, "walk-up err: " .. tostring(err))
  local tb = vim.fn.bufadd(tgt_path)
  vim.fn.bufload(tb)
  local tgt_lines = read_lines(tb)
  assert(
    tgt_lines[2] == "** Alpha",
    "walked-up refile placed Alpha; got '" .. (tgt_lines[2] or "") .. "'"
  )
  vim.fn.delete(tmp, "rf")
end

io.write("refile ok\n")
os.exit(0)
