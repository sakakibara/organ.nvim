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
  local b = make_buf("* Headline C\n  body text\n", org_path)

  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 80,
    height = 10,
  })
  -- Cursor ON the headline -- the normal place to start attaching from.
  vim.api.nvim_win_set_cursor(w, { 1, 3 })

  -- auto_insert_link = true (default).
  local err = attach.attach(b, 1, src)
  assert(err == nil, "test4: attach error: " .. tostring(err))

  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  assert(
    lines[1] == "* Headline C",
    "test4: headline must survive the attach, got: " .. tostring(lines[1])
  )
  -- The link goes on its own line at the head of the body, never spliced
  -- into the headline or into the :PROPERTIES: drawer holding the new :ID:.
  local link_row
  for i, l in ipairs(lines) do
    if l:find("[[attachment:linked.txt]]", 1, true) then
      link_row = i
      break
    end
  end
  assert(link_row, "test4: link not found in buffer (got: " .. joined .. ")")
  assert(
    lines[link_row]:match("^%s*%[%[attachment:linked%.txt%]%]$"),
    "test4: link must be alone on its line, got: " .. lines[link_row]
  )
  local end_row
  for i, l in ipairs(lines) do
    if l:match("^%s*:END:%s*$") then
      end_row = i
    end
  end
  assert(end_row, "test4: expected an :ID: property drawer")
  assert(link_row > end_row, "test4: link landed inside the drawer:\n" .. joined)
  assert(joined:find("  body text", 1, true), "test4: body line must survive intact:\n" .. joined)

  -- Emacs stores the attachment link (`org-attach-store-link-p` defaults
  -- to `attached`) whether or not it is inserted.
  local stored = require("organ.link_store").list()[1]
  assert(stored and stored.url == "attachment:linked.txt", "test4: link not stored")

  vim.api.nvim_win_close(w, true)
end

-- ─── Test 4b: cursor in the body inserts at the cursor ───────────────────────
do
  local src = tmp .. "/inline.txt"
  local fh = assert(io.open(src, "w"))
  fh:write("inline content")
  fh:close()

  local org_path = tmp .. "/attach4b.org"
  local b = make_buf("* Headline E\n:PROPERTIES:\n:ID: 0192abcdef00\n:END:\nsee  here\n", org_path)

  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 80,
    height = 10,
  })
  vim.api.nvim_win_set_cursor(w, { 5, 4 })

  local err = attach.attach(b, 1, src)
  assert(err == nil, "test4b: attach error: " .. tostring(err))

  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    lines[5] == "see [[attachment:inline.txt]] here",
    "test4b: expected in-line insertion at cursor, got: " .. tostring(lines[5])
  )

  vim.api.nvim_win_close(w, true)
end

-- ─── Test 5: `~` in the source path is expanded ──────────────────────────────
do
  local home = tmp .. "/home"
  vim.fn.mkdir(home, "p")
  local saved_home = vim.env.HOME
  vim.env.HOME = home
  assert(vim.fn.expand("~") == home, "test5: HOME override not applied")
  local fh = assert(io.open(home .. "/tilde.txt", "w"))
  fh:write("tilde")
  fh:close()

  local org_path = tmp .. "/attach5.org"
  local b = make_buf("* Headline D\n  body\n", org_path)
  local orig_cfg = require("organ").config.attach
  require("organ").config.attach = vim.tbl_extend("force", orig_cfg, { auto_insert_link = false })

  local err = attach.attach(b, 1, "~/tilde.txt")
  assert(err == nil, "test5: attach returned error: " .. tostring(err))
  local files = attach.list(b, 1)
  assert(files and #files == 1, "test5: expected 1 attached file")
  assert(vim.fn.fnamemodify(files[1], ":t") == "tilde.txt", "test5: got " .. files[1])

  require("organ").config.attach = orig_cfg
  vim.env.HOME = saved_home
end

-- ─── Test 6: unreadable source returns an error before touching the buffer ───
do
  local org_path = tmp .. "/attach6.org"
  local b = make_buf("* Headline E\n  body\n", org_path)
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local orig_cfg = require("organ").config.attach
  require("organ").config.attach = vim.tbl_extend("force", orig_cfg, { auto_insert_link = false })

  local ok, err = pcall(attach.attach, b, 1, tmp .. "/does-not-exist.txt")
  assert(ok, "test6: attach raised: " .. tostring(err))
  assert(
    type(err) == "string" and err:find("does-not-exist.txt", 1, true),
    "test6: err=" .. tostring(err)
  )
  local after = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(
    vim.deep_equal(after, before),
    "test6: buffer modified on failed attach: " .. vim.inspect(after)
  )

  require("organ").config.attach = orig_cfg
end

-- ─── Test 7: `attach.dir` is file-relative, as `org-attach-id-dir` is ───────
-- Emacs: `(defcustom org-attach-id-dir "data/" ...)` -- "If this is a
-- relative path, it will be interpreted relative to the directory where the
-- Org file lives."  A file in a subdirectory therefore gets its own
-- `data/`, and an absolute setting is still used verbatim.
do
  local sub = tmp .. "/sub"
  vim.fn.mkdir(sub, "p")
  local org_path = sub .. "/rel.org"
  local b = make_buf("* Headline F\n  body\n", org_path)

  local orig_cfg = require("organ").config.attach
  require("organ").config.attach =
    vim.tbl_extend("force", orig_cfg, { dir = "data", auto_insert_link = false })

  local id = require("organ.id").get_or_create(b, 1)
  local d = assert(attach.dir(b, 1))
  assert(
    d == sub .. "/data/" .. id:sub(1, 2) .. "/" .. id:sub(3),
    "test7: expected a data/ dir beside the org file, got " .. d
  )
  assert(attach.base_dir(b) == sub .. "/data", "test7: base_dir: " .. attach.base_dir(b))

  -- An absolute `attach.dir` is still absolute.
  require("organ").config.attach =
    vim.tbl_extend("force", orig_cfg, { dir = tmp .. "/abs", auto_insert_link = false })
  assert(attach.base_dir(b) == tmp .. "/abs", "test7: absolute dir: " .. attach.base_dir(b))

  -- An attachment dir that already exists under `<org_dir>/<attach.dir>` is
  -- still found, so files attached before this became file-relative are not
  -- orphaned.
  require("organ").config.attach =
    vim.tbl_extend("force", orig_cfg, { dir = "data", auto_insert_link = false })
  local legacy = tmp .. "/data/" .. id:sub(1, 2) .. "/" .. id:sub(3)
  vim.fn.mkdir(legacy, "p")
  vim.fn.delete(sub .. "/data", "rf")
  assert(attach.dir(b, 1) == legacy, "test7: legacy root not used: " .. tostring(attach.dir(b, 1)))
  vim.fn.delete(tmp .. "/data", "rf")

  require("organ").config.attach = orig_cfg
end

vim.fn.delete(tmp, "rf")
io.write("attach ok\n")
os.exit(0)
