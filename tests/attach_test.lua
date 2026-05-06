-- tests/attach_test.lua
-- Tests for lua/organ/attach.lua (:Org attach, :Org attach open)
-- Run via: nvim --headless -l tests/attach_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local attach_dir = tmp .. "/data"

require("organ").setup({
  db_path = tmp .. "/attach_test.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  attach = {
    enabled = true,
    dir = attach_dir,
    auto_insert_link = true,
    use_symlinks = false,
  },
})

local attach = require("organ.attach")

-- Helper: create a minimal org buffer with a headline.
local function make_buf(text, path)
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n", { plain = true }))
  return b
end

-- ─── Test 1: dir_for_id layout matches Emacs convention ──────────────────────
do
  local id = "0192abcdef1234567890abcdef123456"
  local d = attach.dir_for_id("/base", id)
  assert(
    d == "/base/01/92abcdef1234567890abcdef123456",
    "test1: dir_for_id layout wrong, got: " .. tostring(d)
  )
end

-- ─── Test 2: attach file → directory created, file copied ────────────────────
do
  -- Create a source file to attach.
  local src = tmp .. "/doc.txt"
  local fh = assert(io.open(src, "w"))
  fh:write("hello attach")
  fh:close()

  -- Create a buffer with a headline (no existing ID).
  local org_path = tmp .. "/attach2.org"
  local b = make_buf("* Headline A\n  some body\n", org_path)

  -- Disable auto_insert_link for this test so we don't need a real window.
  local orig_cfg = require("organ").config.attach
  require("organ").config.attach = vim.tbl_extend("force", orig_cfg, { auto_insert_link = false })

  local err = attach.attach(b, 1, src)
  assert(err == nil, "test2: attach returned error: " .. tostring(err))

  -- Find the ID that was created.
  local prop = require("organ.property")
  local entries = prop.list(b, 1) or {}
  local id = nil
  for _, e in ipairs(entries) do
    if e.key == "ID" then
      id = e.value
      break
    end
  end
  assert(id ~= nil, "test2: :ID: property should have been created")
  assert(#id >= 3, "test2: ID too short: " .. tostring(id))

  -- Verify directory structure: <attach_dir>/<id[:2]>/<id[3:]>/
  local expected_dir = attach_dir .. "/" .. id:sub(1, 2) .. "/" .. id:sub(3)
  assert(vim.loop.fs_stat(expected_dir), "test2: attachment dir not created: " .. expected_dir)

  -- Verify file was copied.
  local dest = expected_dir .. "/doc.txt"
  assert(vim.loop.fs_stat(dest), "test2: attached file not found at: " .. dest)
  local content = table.concat(vim.fn.readfile(dest), "\n")
  assert(content == "hello attach", "test2: file content mismatch: " .. content)

  require("organ").config.attach = orig_cfg
end

-- ─── Test 3: list returns attached files ─────────────────────────────────────
do
  local src1 = tmp .. "/file_a.txt"
  local src2 = tmp .. "/file_b.txt"
  for _, p in ipairs({ src1, src2 }) do
    local fh = assert(io.open(p, "w"))
    fh:write("data")
    fh:close()
  end

  local org_path = tmp .. "/attach3.org"
  local b = make_buf("* Headline B\n  body\n", org_path)

  local orig_cfg = require("organ").config.attach
  require("organ").config.attach = vim.tbl_extend("force", orig_cfg, { auto_insert_link = false })

  local err1 = attach.attach(b, 1, src1)
  local err2 = attach.attach(b, 1, src2)
  assert(err1 == nil, "test3: attach src1 error: " .. tostring(err1))
  assert(err2 == nil, "test3: attach src2 error: " .. tostring(err2))

  local files, lerr = attach.list(b, 1)
  assert(lerr == nil, "test3: list error: " .. tostring(lerr))
  assert(
    files ~= nil and #files == 2,
    "test3: expected 2 attached files, got " .. tostring(files and #files or "nil")
  )

  -- Both basenames should be present.
  local names = {}
  for _, f in ipairs(files) do
    names[vim.fn.fnamemodify(f, ":t")] = true
  end
  assert(names["file_a.txt"], "test3: file_a.txt not in list")
  assert(names["file_b.txt"], "test3: file_b.txt not in list")

  require("organ").config.attach = orig_cfg
end

-- ─── Test 4: auto_insert_link inserts [[attachment:...]] at cursor ────────────
do
  local src = tmp .. "/linked.txt"
  local fh = assert(io.open(src, "w"))
  fh:write("linked content")
  fh:close()

  local org_path = tmp .. "/attach4.org"
  local b = make_buf("* Headline C\n  \n", org_path)

  -- Point cursor at line 2 (body line with a space) — column 0.
  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 80,
    height = 10,
  })
  vim.api.nvim_win_set_cursor(w, { 2, 2 })

  -- auto_insert_link = true (default).
  local err = attach.attach(b, 1, src)
  assert(err == nil, "test4: attach error: " .. tostring(err))

  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local found_link = false
  for _, l in ipairs(lines) do
    if l:find("[[attachment:linked.txt]]", 1, true) then
      found_link = true
      break
    end
  end
  assert(
    found_link,
    "test4: [[attachment:linked.txt]] not found in buffer (got: "
      .. table.concat(lines, " | ")
      .. ")"
  )

  vim.api.nvim_win_close(w, true)
end

vim.fn.delete(tmp, "rf")
io.write("attach ok\n")
os.exit(0)
