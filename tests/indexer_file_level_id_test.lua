-- File-level :ID: indexing — covers the indexer.extract_file_level()
-- code path I added. Verifies:
--   1. File with file-level :ID: + heading → both indexed.
--   2. File with file-level :ID: only → only the synthetic node.
--   3. File with no file-level :ID: → no synthetic node (heading-only).
--   4. File with property drawer that lacks :ID: → no synthetic node.
--   5. Title fallback: file with :ID: but no #+title: → uses basename.
--
-- Run via: nvim --headless -l tests/indexer_file_level_id_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
if vim.fn.filereadable(parser_path) ~= 1 then
  io.write("(skipped: parser not installed)\nindexer_file_level_id_test: SKIP\n")
  os.exit(0)
end

local indexer = require("organ.indexer")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function index_text(src, file_path)
  return indexer.extract(src, file_path or "/tmp/x.org", parser_path)
end

-- 1. File-level :ID: with heading → 2 records (file + heading).
do
  local src = ":PROPERTIES:\n:ID: file-id-1\n:END:\n#+title: My Note\n\n* First heading\n  body\n"
  local hls = index_text(src)
  check("file+heading: 2 records", #hls == 2, "got " .. #hls)
  check(
    "file+heading: first is the file-level node",
    hls[1].level == 0 and hls[1].id == "file-id-1" and hls[1].title == "My Note",
    "got " .. vim.inspect(hls[1])
  )
  check(
    "file+heading: second is the heading",
    hls[2].level == 1 and hls[2].title == "First heading",
    "got " .. vim.inspect(hls[2])
  )
end

-- 2. File-level :ID: only (no headings) → 1 record (the synthetic node).
do
  local src = ":PROPERTIES:\n:ID: only-file\n:END:\n#+title: Solo\n"
  local hls = index_text(src)
  check("file-only: exactly 1 record", #hls == 1, "got " .. #hls)
  if #hls >= 1 then
    check(
      "file-only: it's the synthetic node",
      hls[1].level == 0 and hls[1].id == "only-file" and hls[1].title == "Solo"
    )
  end
end

-- 3. No file-level :ID: → no synthetic node.
do
  local src = "#+title: No File ID\n\n* Heading A\n* Heading B\n"
  local hls = index_text(src)
  check("no-file-id: only headings indexed (2 records)", #hls == 2, "got " .. #hls)
  for _, h in ipairs(hls) do
    check("no-file-id: no level-0 record", h.level >= 1, "got level=" .. tostring(h.level))
  end
end

-- 4. Property drawer present but no :ID: in it → no synthetic node.
do
  local src = ":PROPERTIES:\n:CATEGORY: notes\n:END:\n#+title: Without ID\n\n* H\n"
  local hls = index_text(src)
  check(
    "drawer-no-ID: no synthetic record (only the heading)",
    #hls == 1 and hls[1].level == 1,
    "got " .. vim.inspect(vim.tbl_map(function(h)
      return h.level
    end, hls))
  )
end

-- 5. File-level :ID: but no #+title: → falls back to basename.
do
  local src = ":PROPERTIES:\n:ID: titleless\n:END:\n\n* H\n"
  local hls = index_text(src, "/tmp/special-name.org")
  local file_node
  for _, h in ipairs(hls) do
    if h.level == 0 then
      file_node = h
    end
  end
  check("titleless: synthetic node exists", file_node ~= nil)
  check(
    "titleless: title falls back to basename",
    file_node and file_node.title == "special-name",
    "got " .. tostring(file_node and file_node.title)
  )
end

-- 6. File-level :ID: must NOT shadow heading-level :ID: with same value
--    (different files happen to have the same file-level :ID: — unlikely
--    but possible). Each scan is per-file; collision is the indexer's
--    responsibility on the DB-write side, not extraction. We just confirm
--    the same scan doesn't dedupe against itself.
do
  local src =
    ":PROPERTIES:\n:ID: shared-id\n:END:\n#+title: T\n\n* Heading\n  :PROPERTIES:\n  :ID: shared-id\n  :END:\n"
  local hls = index_text(src)
  check(
    "collision: both records emitted (dedup is DB-side, not indexer)",
    #hls == 2,
    "got " .. #hls
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("indexer_file_level_id_test: PASS")
