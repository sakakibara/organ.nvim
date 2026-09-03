-- tests/archive_test.lua
-- Tests for lua/organ/archive.lua (:Org archive subtree).
-- Run via: nvim --headless -l tests/archive_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

-- Minimal organ setup (no DB, no watcher needed).
require("organ").setup({
  db_path = tmp .. "/archive_test.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local archive = require("organ.archive")

-- Helper: load a string into a scratch org buffer and return bufnr.
local function load_buf(text)
  local path = tmp .. "/src_" .. vim.fn.tempname():match("[^/]+$") .. ".org"
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n"))
  return b, path
end

-- Helper: read lines from a path.
local function read_lines(path)
  if not vim.loop.fs_stat(path) then
    return {}
  end
  return vim.fn.readfile(path)
end

-- Helper: read all lines from a buffer.
local function buf_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- ─── Test 1: Basic archive ────────────────────────────────────────────────────
do
  local src_path = tmp .. "/basic.org"
  local arc_path = src_path .. "_archive"
  -- Remove any leftover archive from earlier runs.
  pcall(vim.fn.delete, arc_path)

  local fh = assert(io.open(src_path, "w"))
  fh:write("* TODO Done item\n  body line\n")
  fh:close()
  local b = vim.fn.bufadd(src_path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO Done item",
    "  body line",
  })

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  assert(err == nil, "test1: archive returned error: " .. tostring(err))

  -- Source buffer should now be empty (or have only blank lines).
  local remaining = buf_lines(b)
  local non_empty = 0
  for _, l in ipairs(remaining) do
    if l:match("%S") then
      non_empty = non_empty + 1
    end
  end
  assert(
    non_empty == 0,
    "test1: source buffer should have no content after archive, got: "
      .. table.concat(remaining, "|")
  )

  -- With Emacs default `location = "%s_archive::"` (no wrapper
  -- headline), the archived subtree appears at the archive file's
  -- top level.  The headline keeps its TODO keyword
  -- (`org-archive-mark-done` defaults to nil) and ARCHIVE_TODO
  -- records it as well.
  local arc_lines = read_lines(arc_path)
  local found_item, found_time, found_todo = false, false, false
  for _, l in ipairs(arc_lines) do
    if l == "* TODO Done item" then
      found_item = true
    end
    if l:match(":ARCHIVE_TIME:") then
      found_time = true
    end
    if l:match("^:ARCHIVE_TODO: TODO$") then
      found_todo = true
    end
  end
  assert(
    found_item,
    "test1: archive file missing '* TODO Done item' (got: " .. table.concat(arc_lines, "|") .. ")"
  )
  assert(found_time, "test1: archive file missing :ARCHIVE_TIME: property")
  assert(found_todo, "test1: archive file missing :ARCHIVE_TODO: TODO")
end

-- ─── Test 2: Archive file already exists (append new item) ───────────────────
do
  local src_path = tmp .. "/append.org"
  local arc_path = src_path .. "_archive"

  -- Pre-create archive with an existing item.
  local fh = assert(io.open(arc_path, "w"))
  fh:write("* Archive\n** Old item\n   old body\n")
  fh:close()

  fh = assert(io.open(src_path, "w"))
  fh:write("* New item\n  new body\n")
  fh:close()
  local b = vim.fn.bufadd(src_path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* New item", "  new body" })

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  assert(err == nil, "test2: archive error: " .. tostring(err))

  -- Archive file pre-populated with a wrapper-style layout; with
  -- the new default (no wrapper) the new item lands at level 1 as
  -- a sibling of "* Archive", and the old level-2 entry is left
  -- intact under it.
  local arc_lines = read_lines(arc_path)
  local found_old, found_new = false, false
  for _, l in ipairs(arc_lines) do
    if l:match("^%*%* Old item") then
      found_old = true
    end
    if l:match("^%* New item") then
      found_new = true
    end
  end
  assert(found_old, "test2: Old item disappeared from archive")
  assert(
    found_new,
    "test2: New item not added to archive (got: " .. table.concat(arc_lines, "|") .. ")"
  )
end

-- ─── Test 3: Re-leveling nested headlines ─────────────────────────────────────
do
  -- Source: level-2 child "** Child" under "* Parent".  With the
  -- default no-wrapper location, archiving "* Parent" preserves
  -- structure: "* Parent" + "** Child" in the archive file.  (When
  -- a wrapper headline IS configured, the subtree gets demoted by
  -- one to nest under it -- see archive_emacs_parity_test for the
  -- wrapper case.)
  local src_path = tmp .. "/relevel.org"
  local arc_path = src_path .. "_archive"
  pcall(vim.fn.delete, arc_path)

  local fh = assert(io.open(src_path, "w"))
  fh:write("* Parent\n** Child\n   body\n")
  fh:close()
  local b = vim.fn.bufadd(src_path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Parent", "** Child", "   body" })

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  assert(err == nil, "test3: archive error: " .. tostring(err))

  local arc_lines = read_lines(arc_path)
  local found_parent_l2, found_child_l3 = false, false
  for _, l in ipairs(arc_lines) do
    if l == "* Parent" then
      found_parent_l2 = true
    end
    if l == "** Child" then
      found_child_l3 = true
    end
  end
  assert(
    found_parent_l2,
    "test3: expected '* Parent' in archive (got: " .. table.concat(arc_lines, "|") .. ")"
  )
  assert(
    found_child_l3,
    "test3: expected '** Child' in archive (got: " .. table.concat(arc_lines, "|") .. ")"
  )
end

-- ─── Test 4: Metadata injected (ARCHIVE_TIME + ARCHIVE_FILE) ─────────────────
do
  local src_path = tmp .. "/meta.org"
  local arc_path = src_path .. "_archive"
  pcall(vim.fn.delete, arc_path)

  local fh = assert(io.open(src_path, "w"))
  fh:write("* Meta item\n")
  fh:close()
  local b = vim.fn.bufadd(src_path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Meta item" })

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  assert(err == nil, "test4: archive error: " .. tostring(err))

  local arc_lines = read_lines(arc_path)
  local found_time, found_file = false, false
  -- Emacs ARCHIVE_TIME has NO `[ ]` brackets (per
  -- `(substring (cdr org-time-stamp-formats) 1 -1)`).  Just the
  -- bare `YYYY-MM-DD Dow HH:MM`.
  local today_prefix = os.date("%Y-%m-%d", os.time())
  for _, l in ipairs(arc_lines) do
    if l:match(":ARCHIVE_TIME:") then
      found_time = true
      assert(
        l:find(today_prefix, 1, true),
        "test4: ARCHIVE_TIME does not contain today's date in: " .. l
      )
      assert(not l:find("[", 1, true), "test4: ARCHIVE_TIME should not have brackets, got: " .. l)
    end
    if l:match(":ARCHIVE_FILE:") then
      found_file = true
      assert(
        l:find("meta.org", 1, true),
        "test4: ARCHIVE_FILE should reference source file, got: " .. l
      )
    end
  end
  assert(found_time, "test4: :ARCHIVE_TIME: not found in archive properties")
  assert(found_file, "test4: :ARCHIVE_FILE: not found in archive properties")
end

-- ─── Test 5: archive.enabled = false → command disabled ──────────────────────
do
  -- After calling setup() with archive.enabled=false, OrgArchiveSubtree should
  -- be removed from the global command namespace.
  require("organ").config = require("organ.defaults")
  require("organ").setup({
    db_path = tmp .. "/arc_dis.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    archive = { enabled = false },
  })
  local cmds = vim.api.nvim_get_commands({})
  assert(
    cmds.OrgArchiveSubtree == nil,
    "test5: OrgArchiveSubtree should not exist when archive.enabled=false"
  )

  -- Restore for remaining tests.
  require("organ").config = require("organ.defaults")
  require("organ").setup({
    db_path = tmp .. "/arc_re.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })
end

-- ─── Test 6: Custom wrapper headline via `location` string ──────────────────
do
  local src_path = tmp .. "/customhl.org"
  local arc_path = src_path .. "_archive"
  pcall(vim.fn.delete, arc_path)

  local fh = assert(io.open(src_path, "w"))
  fh:write("* Custom item\n")
  fh:close()
  local b = vim.fn.bufadd(src_path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Custom item" })

  -- `location` with explicit wrapper headline -- archived subtree
  -- gets demoted to nest under it.
  local orig_cfg = require("organ").config.archive
  require("organ").config.archive =
    vim.tbl_extend("force", orig_cfg, { location = "%s_archive::* Done" })

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  assert(err == nil, "test6: archive error: " .. tostring(err))

  require("organ").config.archive = orig_cfg

  local arc_lines = read_lines(arc_path)
  local found_done_hl, found_item = false, false
  for _, l in ipairs(arc_lines) do
    if l:match("^%* Done") then
      found_done_hl = true
    end
    if l:match("^%*%* Custom item") then
      found_item = true
    end
  end
  assert(
    found_done_hl,
    "test6: expected '* Done' headline in archive (got: " .. table.concat(arc_lines, "|") .. ")"
  )
  assert(
    found_item,
    "test6: expected '** Custom item' under Done (got: " .. table.concat(arc_lines, "|") .. ")"
  )
end

-- ─── Test 7: Custom dynamic destination via `location` function form ─────────
do
  local all_archive = tmp .. "/all_archive.org"
  pcall(vim.fn.delete, all_archive)

  local src_path = tmp .. "/fnpat.org"
  local fh = assert(io.open(src_path, "w"))
  fh:write("* FnPat item\n")
  fh:close()
  local b = vim.fn.bufadd(src_path)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* FnPat item" })

  -- `location` as a function (organ extension over Emacs's
  -- string-only `org-archive-location`) -- returns a location
  -- string computed from src_path.
  local orig_cfg = require("organ").config.archive
  require("organ").config.archive = vim.tbl_extend("force", orig_cfg, {
    location = function(_)
      return all_archive .. "::"
    end,
  })

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  assert(err == nil, "test7: archive error: " .. tostring(err))

  require("organ").config.archive = orig_cfg

  local lines = read_lines(all_archive)
  local found = false
  for _, l in ipairs(lines) do
    if l:match("FnPat item") then
      found = true
    end
  end
  assert(
    found,
    "test7: FnPat item should be in custom archive path (got: " .. table.concat(lines, "|") .. ")"
  )
end

-- ─── Test 8: planning line stays first; injected drawer follows it ──────────
-- Also: TODO keyword kept on the moved headline; column-zero emphasis
-- is not re-leveled when the subtree is demoted under a wrapper.
do
  local src_path = tmp .. "/plan.org"
  local arc_path = src_path .. "_archive"
  pcall(vim.fn.delete, arc_path)
  local b = load_buf("* TODO Task\nSCHEDULED: <2026-01-01 Thu>\nbody\n*bold* at col 0\n** Sub\n")
  vim.api.nvim_buf_set_name(b, src_path)
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent! write!")
  end)

  local orig_cfg = require("organ").config.archive
  require("organ").config.archive =
    vim.tbl_extend("force", orig_cfg, { location = "%s_archive::* Archive" })
  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  require("organ").config.archive = orig_cfg
  assert(err == nil, "test8: archive error: " .. tostring(err))

  local arc_lines = read_lines(arc_path)
  local start
  for i, l in ipairs(arc_lines) do
    if l == "** TODO Task" then
      start = i
    end
  end
  assert(start, "test8: expected '** TODO Task' (got: " .. table.concat(arc_lines, "|") .. ")")
  assert(
    arc_lines[start + 1] == "SCHEDULED: <2026-01-01 Thu>",
    "test8: planning line must directly follow the headline; got " .. tostring(arc_lines[start + 1])
  )
  assert(arc_lines[start + 2] == ":PROPERTIES:", "test8: drawer must follow the planning line")
  local rest = table.concat(arc_lines, "\n", start)
  assert(rest:find("\n*bold* at col 0\n", 1, true), "test8: emphasis line altered:\n" .. rest)
  assert(rest:find("\n*** Sub", 1, true), "test8: child not demoted:\n" .. rest)
end

-- ─── Test 9: same-file location `::* Archive` ────────────────────────────────
do
  local b, src_path =
    load_buf("#+ARCHIVE: ::* Archive\n* Keep\n* DONE Old task\nold body\n* Last\n")
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent! write!")
  end)
  local err, arc_path = archive.archive_subtree({ bufnr = b, line = 3 })
  assert(err == nil, "test9: archive error: " .. tostring(err))
  assert(
    vim.fn.resolve(arc_path) == vim.fn.resolve(src_path),
    "test9: archive path should be the source file; got " .. tostring(arc_path)
  )
  assert(not vim.bo[b].modified, "test9: buffer should be written")
  local lines = read_lines(src_path)
  local joined = table.concat(lines, "\n")
  assert(
    lines[1] == "#+ARCHIVE: ::* Archive" and lines[2] == "* Keep" and lines[3] == "* Last",
    joined
  )
  assert(lines[4] == "* Archive" and lines[5] == "** DONE Old task", joined)
  assert(lines[#lines] == "old body", joined)
  assert(
    not joined:find("\n* DONE Old task", 1, true),
    "test9: original subtree still present:\n" .. joined
  )
  assert(table.concat(buf_lines(b), "\n") == joined, "test9: buffer and file differ")

  -- A second archive into the same file reuses the wrapper.
  err = archive.archive_subtree({ bufnr = b, line = 2 })
  assert(err == nil, "test9b: archive error: " .. tostring(err))
  lines = read_lines(src_path)
  joined = table.concat(lines, "\n")
  local wrappers = 0
  for _, l in ipairs(lines) do
    if l == "* Archive" then
      wrappers = wrappers + 1
    end
  end
  assert(wrappers == 1, "test9b: wrapper duplicated:\n" .. joined)
  assert(lines[2] == "* Last" and lines[3] == "* Archive", joined)
  assert(joined:find("\n** Keep\n", 1, true), "test9b: Keep not under Archive:\n" .. joined)
end

-- ─── Test 10: wrapper headline carrying tags is reused ───────────────────────
-- Emacs matches the heading text followed by an optional tag block.
-- The parent's non-ASCII tag is inherited into ARCHIVE_ITAGS.
do
  local src_path = tmp .. "/tagged.org"
  local arc_path = src_path .. "_archive"
  vim.fn.writefile({ "* Archive :ARCHIVE:", "** Earlier" }, arc_path)
  local b = load_buf("* Parent :仕事:\n** DONE A\n** DONE B\n")
  vim.api.nvim_buf_set_name(b, src_path)
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent! write!")
  end)

  local orig_cfg = require("organ").config.archive
  require("organ").config.archive =
    vim.tbl_extend("force", orig_cfg, { location = "%s_archive::* Archive" })
  local err = archive.archive_subtree({ bufnr = b, line = 2 })
  require("organ").config.archive = orig_cfg
  assert(err == nil, "test10: archive error: " .. tostring(err))

  local lines = read_lines(arc_path)
  local joined = table.concat(lines, "\n")
  assert(lines[1] == "* Archive :ARCHIVE:" and lines[2] == "** Earlier", joined)
  for _, l in ipairs(lines) do
    assert(l ~= "* Archive", "test10: duplicate wrapper created:\n" .. joined)
  end
  assert(lines[3] == "** DONE A", "test10: entry should follow Earlier:\n" .. joined)
  assert(
    joined:find(":ARCHIVE_ITAGS: 仕事", 1, true),
    "test10: non-ASCII tag not inherited:\n" .. joined
  )
end

-- ─── Test 11: location heading carrying tags matches an existing wrapper ─────
do
  local b, src_path =
    load_buf("#+ARCHIVE: ::* Archive :tag:\n* Keep\n* DONE Old\n* Archive :tag:\n** Earlier\n")
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent! write!")
  end)
  local err = archive.archive_subtree({ bufnr = b, line = 3 })
  assert(err == nil, "test11: archive error: " .. tostring(err))
  local lines = read_lines(src_path)
  local joined = table.concat(lines, "\n")
  local wrappers = 0
  for _, l in ipairs(lines) do
    if l == "* Archive :tag:" then
      wrappers = wrappers + 1
    end
  end
  assert(wrappers == 1, "test11: wrapper duplicated:\n" .. joined)
  assert(
    lines[2] == "* Keep" and lines[3] == "* Archive :tag:" and lines[4] == "** Earlier",
    joined
  )
  assert(lines[5] == "** DONE Old", "test11: entry should follow Earlier:\n" .. joined)
end

vim.fn.delete(tmp, "rf")
io.write("archive ok\n")
os.exit(0)
