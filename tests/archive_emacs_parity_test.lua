-- Archive parity with Emacs `org-archive-subtree`:
--   1. ARCHIVE_TIME has no `[ ]` brackets.
--   2. ARCHIVE_FILE is written via `abbreviate-file-name` (~ prefix).
--   3. ARCHIVE_ITAGS is the INHERITED tag set (ancestor tags +
--      #+FILETAGS), not just the direct tags on the moved headline.
--   4. The archive file is prefixed once with
--      `# Archived entries from file <path>` when first written.
--   5. `archive.location` parses Emacs `org-archive-location` syntax,
--      and `#+ARCHIVE:` / `:ARCHIVE:` overrides take precedence.
--
-- Run via: nvim --headless -l tests/archive_emacs_parity_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/archive_parity.db",
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
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n"))
  return b
end

-- 1 + 2 + 4: ARCHIVE_TIME format, ARCHIVE_FILE ~-prefix, source header.
do
  local src = tmp .. "/parity1.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* Item one\nbody\n", src)
  local err = archive.archive_subtree({ bufnr = b, line = 1 })
  check("archive_subtree succeeds", err == nil, tostring(err))

  local lines = read_lines(arc)
  local body = table.concat(lines, "\n")

  -- ARCHIVE_TIME without brackets.
  local time_line = body:match("\n(:ARCHIVE_TIME:[^\n]+)")
  check("ARCHIVE_TIME present", time_line ~= nil, vim.inspect(lines))
  check(
    "ARCHIVE_TIME has no `[` bracket",
    time_line and not time_line:find("[", 1, true),
    "got " .. tostring(time_line)
  )
  check(
    "ARCHIVE_TIME matches `YYYY-MM-DD Dow HH:MM`",
    time_line and time_line:match("^:ARCHIVE_TIME: %d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d$") ~= nil,
    "got " .. tostring(time_line)
  )

  -- ARCHIVE_FILE uses `~` when path is under $HOME (skip the
  -- assertion if test tmpdir doesn't land under $HOME).
  local file_line = body:match("\n(:ARCHIVE_FILE:[^\n]+)")
  check("ARCHIVE_FILE present", file_line ~= nil)
  local home = vim.fn.expand("$HOME")
  if home and src:sub(1, #home) == home then
    check(
      "ARCHIVE_FILE has `~` prefix when source is under $HOME",
      file_line and file_line:find("~/", 1, true) ~= nil,
      "got " .. tostring(file_line)
    )
  end

  -- Source header comment.
  check(
    "first archive write adds `# Archived entries from file ...` header",
    lines[1] and lines[1]:match("^# Archived entries from file ") ~= nil,
    "got line 1 = " .. tostring(lines[1])
  )

  -- Header should NOT be re-added on subsequent archives into the
  -- same archive file (Emacs only writes the comment when the
  -- archive buffer is empty).
  local src2 = tmp .. "/parity1b.org"
  pcall(vim.fn.delete, src2)
  -- Same archive file (parity1b's archive resolves to parity1b_archive,
  -- different from parity1's; use a custom location so they share one).
  local b2 = load_buf("* Item two\n", src2)
  local orig = require("organ").config.archive
  require("organ").config.archive = vim.tbl_extend(
    "force", orig, { location = arc .. "::* Archive" }
  )
  archive.archive_subtree({ bufnr = b2, line = 1 })
  require("organ").config.archive = orig

  local lines2 = read_lines(arc)
  local header_count = 0
  for _, l in ipairs(lines2) do
    if l:match("^# Archived entries from file ") then
      header_count = header_count + 1
    end
  end
  check(
    "source header is written ONCE, not per archive call",
    header_count == 1,
    "header_count=" .. header_count
  )
end

-- 3: ARCHIVE_ITAGS = ancestor + #+FILETAGS, not just direct tags.
do
  local src = tmp .. "/parity2.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf(
    table.concat({
      "#+FILETAGS: :inbox:project:",
      "",
      "* Parent :home:",
      "** Child to archive :urgent:",
      "body line",
    }, "\n") .. "\n",
    src
  )
  archive.archive_subtree({ bufnr = b, line = 4 }) -- cursor on ** Child
  local lines = read_lines(arc)
  local itags_line
  for _, l in ipairs(lines) do
    if l:match("^:ARCHIVE_ITAGS:") then
      itags_line = l
      break
    end
  end
  check("ARCHIVE_ITAGS present when ancestors / filetags have tags", itags_line ~= nil)
  if itags_line then
    -- inherited = parent's "home" + filetags "inbox" + "project".
    -- The DIRECT tag "urgent" travels with the headline title and
    -- is NOT in ARCHIVE_ITAGS (Emacs inherit-only semantic).
    check("ARCHIVE_ITAGS includes parent's `home` tag", itags_line:find("home", 1, true) ~= nil, itags_line)
    check("ARCHIVE_ITAGS includes filetag `inbox`", itags_line:find("inbox", 1, true) ~= nil, itags_line)
    check("ARCHIVE_ITAGS includes filetag `project`", itags_line:find("project", 1, true) ~= nil, itags_line)
    check(
      "ARCHIVE_ITAGS does NOT include the direct `urgent` tag",
      not itags_line:find("urgent", 1, true),
      itags_line
    )
  end
end

-- 5a: archive.location string syntax — no wrapper headline.
do
  local src = tmp .. "/parity3.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* Top-level only\n", src)
  local orig = require("organ").config.archive
  require("organ").config.archive = vim.tbl_extend("force", orig, { location = "%s_archive::" })
  archive.archive_subtree({ bufnr = b, line = 1 })
  require("organ").config.archive = orig

  local lines = read_lines(arc)
  local has_wrapper = false
  local has_top = false
  for _, l in ipairs(lines) do
    if l:match("^%* Archive") then
      has_wrapper = true
    end
    if l:match("^%* Top%-level only") then
      has_top = true
    end
  end
  check("location with empty headline: no `* Archive` wrapper", not has_wrapper, table.concat(lines, "|"))
  check(
    "location with empty headline: subtree stays at level 1",
    has_top,
    table.concat(lines, "|")
  )
end

-- 5b: `#+ARCHIVE:` directive overrides config.
do
  local src = tmp .. "/parity4.org"
  local custom_arc = tmp .. "/custom_via_directive.org"
  pcall(vim.fn.delete, custom_arc)
  local b = load_buf(
    "#+ARCHIVE: " .. custom_arc .. "::* Via directive\n* Item\n",
    src
  )
  archive.archive_subtree({ bufnr = b, line = 2 })

  local lines = read_lines(custom_arc)
  local has_directive_hl = false
  for _, l in ipairs(lines) do
    if l:match("^%* Via directive") then
      has_directive_hl = true
    end
  end
  check(
    "#+ARCHIVE: directive overrides cfg (custom file + headline)",
    has_directive_hl,
    "lines: " .. table.concat(lines, "|")
  )
end

-- 5c: `:ARCHIVE:` subtree property overrides #+ARCHIVE: and config.
do
  local src = tmp .. "/parity5.org"
  local dir_arc = tmp .. "/from_directive.org"
  local prop_arc = tmp .. "/from_property.org"
  pcall(vim.fn.delete, dir_arc)
  pcall(vim.fn.delete, prop_arc)
  local b = load_buf(
    table.concat({
      "#+ARCHIVE: " .. dir_arc .. "::* From directive",
      "",
      "* Item",
      ":PROPERTIES:",
      ":ARCHIVE: " .. prop_arc .. "::* From property",
      ":END:",
      "body",
    }, "\n") .. "\n",
    src
  )
  archive.archive_subtree({ bufnr = b, line = 3 }) -- cursor on * Item

  check(
    ":ARCHIVE: property wins over #+ARCHIVE: directive",
    vim.loop.fs_stat(prop_arc) ~= nil and vim.loop.fs_stat(dir_arc) == nil,
    string.format("prop_arc exists=%s, dir_arc exists=%s",
      tostring(vim.loop.fs_stat(prop_arc) ~= nil),
      tostring(vim.loop.fs_stat(dir_arc) ~= nil))
  )
end

-- write_source_header = false suppresses the header.
do
  local src = tmp .. "/parity6.org"
  local arc = src .. "_archive"
  pcall(vim.fn.delete, arc)
  local b = load_buf("* Item\n", src)
  local orig = require("organ").config.archive
  require("organ").config.archive = vim.tbl_extend("force", orig, { write_source_header = false })
  archive.archive_subtree({ bufnr = b, line = 1 })
  require("organ").config.archive = orig
  local lines = read_lines(arc)
  local has_header = false
  for _, l in ipairs(lines) do
    if l:match("^# Archived entries from file ") then
      has_header = true
    end
  end
  check("write_source_header = false suppresses header", not has_header, table.concat(lines, "|"))
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("archive_emacs_parity_test: PASS")
