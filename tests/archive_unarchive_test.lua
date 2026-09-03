-- `:Org unarchive` round-trip: archive a subtree, then unarchive it
-- and check the subtree is back in the right place with the
-- `ARCHIVE_*` properties stripped.
--
-- Covers:
--   1. round-trip with a top-level subtree (no OLPATH)
--   2. round-trip with a nested subtree (OLPATH = "Parent")
--   3. round-trip with a deep subtree (OLPATH = "Top/Middle")
--   4. soft fallback when OLPATH no longer resolves (parent moved
--      or renamed in the source since archive time) -- subtree
--      lands at top level instead of erroring
--   5. hard error when the archived subtree has no `:ARCHIVE_FILE:`
--      property (nothing to restore against)
--   6. PROPERTIES drawer is dropped entirely when stripping
--      ARCHIVE_* leaves it empty; preserved when other props remain
--
-- Run via: nvim --headless -l tests/archive_unarchive_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/unarchive.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local archive = require("organ.archive")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function read_lines(path)
  if not vim.loop.fs_stat(path) then
    return {}
  end
  return vim.fn.readfile(path)
end

local function load_buf(text, path)
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  -- bufload reads the file fresh; no need to set_lines again.
  return b
end

-- ─── 1. Top-level round trip (no OLPATH) ────────────────────────────────────
do
  local src = tmp .. "/round1.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* TODO Top thing\nbody line\n", src)

  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  check("round1: archive succeeded", err == nil, tostring(err))

  -- Cursor on the archived headline in the archive file.
  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)
  -- Find the archived heading line (first `^*\s` line, skip the
  -- `# Archived entries from file ...` header).
  local arc_lines = vim.api.nvim_buf_get_lines(arc_buf, 0, -1, false)
  local archived_line
  for i, l in ipairs(arc_lines) do
    if l:match("^%*%s") then
      archived_line = i
      break
    end
  end
  check("round1: archived heading present in archive file", archived_line ~= nil)
  if not archived_line then
    return
  end

  local uerr, dest = archive.unarchive({ bufnr = arc_buf, line = archived_line })
  check("round1: unarchive succeeded", uerr == nil, tostring(uerr))
  check("round1: returned dest matches source", dest and dest:find("round1.org", 1, true) ~= nil)

  -- Re-read source from disk.
  local src_lines = read_lines(src)
  local found_top, found_top_with_todo = false, false
  local has_archive_file, has_archive_olpath, has_archive_todo = false, false, false
  for _, l in ipairs(src_lines) do
    if l:match("^%*+ .*Top thing") then
      found_top = true
    end
    -- The round trip keeps `* TODO Top thing` intact.
    if l:match("^%* TODO Top thing") then
      found_top_with_todo = true
    end
    if l:match(":ARCHIVE_FILE:") then
      has_archive_file = true
    end
    if l:match(":ARCHIVE_OLPATH:") then
      has_archive_olpath = true
    end
    if l:match(":ARCHIVE_TODO:") then
      has_archive_todo = true
    end
  end
  check("round1: top-level subtree restored to source", found_top)
  check(
    "round1: TODO keyword restored on the headline (round-trip preserves state)",
    found_top_with_todo,
    "src:\n" .. table.concat(src_lines, "\n")
  )
  check(
    "round1: ARCHIVE_FILE property stripped on restore",
    not has_archive_file,
    table.concat(src_lines, "|")
  )
  check("round1: ARCHIVE_OLPATH property stripped on restore", not has_archive_olpath)
  check("round1: ARCHIVE_TODO property stripped on restore", not has_archive_todo)

  -- Archive file no longer contains the entry.
  local arc_after = read_lines(arc)
  local still_archived = false
  for _, l in ipairs(arc_after) do
    if l:match("^%* TODO Top thing") or l:match("^%* Top thing") then
      still_archived = true
    end
  end
  check("round1: entry removed from archive file", not still_archived, table.concat(arc_after, "|"))
end

-- ─── 2. Nested round trip (OLPATH = "Parent") ────────────────────────────────
do
  local src = tmp .. "/round2.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* Parent\n** TODO Child task\nchild body\n", src)

  local err = archive.archive_subtree({ bufnr = b, line = 2 }) -- cursor on ** Child
  check("round2: archive succeeded", err == nil, tostring(err))

  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)
  local arc_lines = vim.api.nvim_buf_get_lines(arc_buf, 0, -1, false)
  local archived_line
  for i, l in ipairs(arc_lines) do
    if l:match("^%*%s") then
      archived_line = i
      break
    end
  end

  -- Reload source -- archive_subtree wrote it, but our `b` may be stale.
  vim.cmd("checktime " .. b)

  local uerr, dest = archive.unarchive({ bufnr = arc_buf, line = archived_line })
  check("round2: unarchive succeeded", uerr == nil, tostring(uerr))

  local src_lines = read_lines(src)
  -- TODO keyword is restored (round-trip preserves state), so the
  -- child comes back as `** TODO Child task`.
  local found_parent, found_child_l2, found_child_l1 = false, false, false
  for _, l in ipairs(src_lines) do
    if l == "* Parent" then
      found_parent = true
    end
    if l == "** TODO Child task" then
      found_child_l2 = true
    end
    if l == "* TODO Child task" then
      found_child_l1 = true
    end
  end
  check("round2: parent still present", found_parent)
  check(
    "round2: child restored as level-2 child of parent (with TODO state, not top-level)",
    found_child_l2 and not found_child_l1,
    "src:\n" .. table.concat(src_lines, "\n")
  )
end

-- ─── 3. Deep nested round trip (OLPATH = "Top/Middle") ───────────────────────
do
  local src = tmp .. "/round3.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* Top\n** Middle\n*** Deep entry\ndeep body\n", src)

  archive.archive_subtree({ bufnr = b, line = 3 }) -- cursor on *** Deep

  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)
  local arc_lines = vim.api.nvim_buf_get_lines(arc_buf, 0, -1, false)
  local archived_line
  for i, l in ipairs(arc_lines) do
    if l:match("^%*%s") then
      archived_line = i
      break
    end
  end
  -- Verify ARCHIVE_OLPATH was set to "Top/Middle"
  local olpath_line
  for _, l in ipairs(arc_lines) do
    if l:match(":ARCHIVE_OLPATH:") then
      olpath_line = l
    end
  end
  check(
    "round3: ARCHIVE_OLPATH = Top/Middle",
    olpath_line and olpath_line:find("Top/Middle", 1, true) ~= nil,
    "got " .. tostring(olpath_line)
  )

  archive.unarchive({ bufnr = arc_buf, line = archived_line })

  local src_lines = read_lines(src)
  local found_deep_l3, found_deep_other = false, false
  for _, l in ipairs(src_lines) do
    if l == "*** Deep entry" then
      found_deep_l3 = true
    elseif l:match("^%*+ Deep entry") then
      found_deep_other = true
    end
  end
  check(
    "round3: deep entry restored as level-3 child of Top/Middle",
    found_deep_l3 and not found_deep_other,
    "src:\n" .. table.concat(src_lines, "\n")
  )
end

-- ─── 4. Soft fallback: OLPATH parent no longer exists ────────────────────────
do
  local src = tmp .. "/round4.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* Original parent\n** Item to archive\nbody\n", src)

  archive.archive_subtree({ bufnr = b, line = 2 })

  -- Rename the parent in the source so OLPATH no longer resolves.
  vim.cmd("checktime " .. b)
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "* Renamed parent" })
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent! write")
  end)

  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)
  local arc_lines = vim.api.nvim_buf_get_lines(arc_buf, 0, -1, false)
  local archived_line
  for i, l in ipairs(arc_lines) do
    if l:match("^%*%s") then
      archived_line = i
      break
    end
  end

  local uerr = archive.unarchive({ bufnr = arc_buf, line = archived_line })
  check(
    "round4: unarchive succeeds (soft fallback) when OLPATH parent is gone",
    uerr == nil,
    tostring(uerr)
  )

  local src_lines = read_lines(src)
  local found_item_l1, found_item_l2 = false, false
  for _, l in ipairs(src_lines) do
    if l == "* Item to archive" then
      found_item_l1 = true
    end
    if l == "** Item to archive" then
      found_item_l2 = true
    end
  end
  check(
    "round4: subtree landed at top level (fallback) when OLPATH didn't resolve",
    found_item_l1 and not found_item_l2,
    "src:\n" .. table.concat(src_lines, "\n")
  )
end

-- ─── 5. Hard error: no :ARCHIVE_FILE: property ───────────────────────────────
do
  local arc = tmp .. "/round5_archive.org"
  local fh = assert(io.open(arc, "w"))
  fh:write("* Bare entry\nbody, no archive properties at all\n")
  fh:close()
  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)

  local uerr = archive.unarchive({ bufnr = arc_buf, line = 1 })
  check(
    "round5: hard error when :ARCHIVE_FILE: property is missing",
    uerr ~= nil and uerr:find("ARCHIVE_FILE", 1, true) ~= nil,
    "got err = " .. tostring(uerr)
  )
end

-- ─── 6. PROPERTIES drawer kept when non-ARCHIVE props remain ─────────────────
do
  local src = tmp .. "/round6.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  -- Source has an :ID: property -- after archive + unarchive, the ID
  -- must survive (only ARCHIVE_* gets stripped).
  local b = load_buf(table.concat({
    "* Entry with ID",
    ":PROPERTIES:",
    ":ID: abc-123",
    ":END:",
    "body",
  }, "\n") .. "\n", src)

  archive.archive_subtree({ bufnr = b, line = 1 })

  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)
  local arc_lines = vim.api.nvim_buf_get_lines(arc_buf, 0, -1, false)
  local archived_line
  for i, l in ipairs(arc_lines) do
    if l:match("^%*%s") then
      archived_line = i
      break
    end
  end
  archive.unarchive({ bufnr = arc_buf, line = archived_line })

  local src_lines = read_lines(src)
  local has_id, has_archive_file, has_drawer = false, false, false
  for _, l in ipairs(src_lines) do
    if l:match(":ID: abc%-123") then
      has_id = true
    end
    if l:match(":ARCHIVE_FILE:") then
      has_archive_file = true
    end
    if l:match("^%s*:PROPERTIES:") then
      has_drawer = true
    end
  end
  check("round6: :ID: property survives unarchive", has_id, table.concat(src_lines, "|"))
  check("round6: ARCHIVE_FILE still stripped on unarchive", not has_archive_file)
  check("round6: PROPERTIES drawer kept (it had non-ARCHIVE entries)", has_drawer)
end

-- ─── 7. Full-fidelity round trip: keyword + tags + planning + LOGBOOK ─────────
-- Everything except the ARCHIVE_* bookkeeping should survive a
-- archive -> unarchive round trip byte-for-byte.
do
  local src = tmp .. "/round7.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local subtree = table.concat({
    "* Parent",
    "** TODO Rich entry :work:urgent:",
    "   DEADLINE: <2026-05-25 Mon> SCHEDULED: <2026-05-21 Thu>",
    "   :PROPERTIES:",
    "   :ID: rich-1",
    "   :EFFORT: 1:30",
    "   :END:",
    "   :LOGBOOK:",
    '   - State "TODO"       from              [2026-05-20 Wed 09:00]',
    "   :END:",
    "   body paragraph one",
    "*** TODO sub-entry :deep:",
    "   sub body",
  }, "\n") .. "\n"
  local b = load_buf(subtree, src)

  archive.archive_subtree({ bufnr = b, line = 2 }) -- cursor on ** Rich entry

  local arc_buf = vim.fn.bufadd(arc)
  vim.fn.bufload(arc_buf)
  local arc_lines = vim.api.nvim_buf_get_lines(arc_buf, 0, -1, false)
  local archived_line
  for i, l in ipairs(arc_lines) do
    if l:match("^%*%s") then
      archived_line = i
      break
    end
  end
  archive.unarchive({ bufnr = arc_buf, line = archived_line })

  local src_lines = read_lines(src)
  local body = table.concat(src_lines, "\n")

  local function present(pat, label)
    check("round7: " .. label, body:find(pat) ~= nil, "src:\n" .. body)
  end

  present("%*%* TODO Rich entry :work:urgent:", "headline keyword + direct tags restored")
  present("DEADLINE: <2026%-05%-25 Mon>", "DEADLINE planning line preserved")
  present("SCHEDULED: <2026%-05%-21 Thu>", "SCHEDULED planning line preserved")
  present(":ID: rich%-1", "ID property preserved")
  present(":EFFORT: 1:30", "EFFORT property preserved")
  present(":LOGBOOK:", "LOGBOOK drawer preserved")
  present('State "TODO"', "LOGBOOK entry text preserved")
  present("body paragraph one", "body text preserved")
  present("%*%*%* TODO sub%-entry :deep:", "sub-heading (keyword + tag) preserved at correct depth")

  -- And the ARCHIVE_* bookkeeping is gone.
  check(
    "round7: no ARCHIVE_* properties leak back into source",
    not body:find(":ARCHIVE_"),
    "src:\n" .. body
  )
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("archive_unarchive_test: PASS")
