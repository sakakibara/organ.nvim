-- Assert that applying sql/schema.sql to a fresh DB yields the expected
-- PRAGMA values, user_version, and indexes.
-- Run via: nvim --headless -l tests/schema_test.lua

local root = vim.fn.getcwd()
local db = os.tmpname() .. ".db"
local rc = os.execute(string.format("sqlite3 %q < %q", db, root .. "/sql/schema.sql"))
assert(rc == 0 or rc == true, "schema apply failed")

local function query(q)
  local r = vim.system({ "sqlite3", db, q }):wait()
  return (r.stdout or ""):gsub("%s+$", "")
end

local checks = {
  { "PRAGMA user_version", "1" },
  { "PRAGMA page_size", "8192" },
  { "PRAGMA auto_vacuum", "2" },
}
for _, c in ipairs(checks) do
  local got = query(c[1])
  if got ~= c[2] then
    io.stderr:write(string.format("%s: got %q, expected %q\n", c[1], got, c[2]))
    os.remove(db)
    os.exit(1)
  end
end

local want_idx = {
  "idx_files_mtime",
  "idx_properties_key",
  "idx_headlines_file",
  "idx_headlines_parent",
  "idx_tags_tag",
  "idx_links_source",
  "idx_links_id_target",
  "idx_headlines_scheduled_date",
  "idx_headlines_deadline_date",
  "idx_headlines_closed_date",
  "idx_file_tags_tag",
  "idx_aliases_alias",
  "idx_habit_completions_date",
  "idx_clock_entries_start",
  "idx_clock_entries_active",
}
for _, name in ipairs(want_idx) do
  local got =
    query(string.format("SELECT name FROM sqlite_master WHERE type='index' AND name='%s'", name))
  if got ~= name then
    io.stderr:write("missing index: " .. name .. "\n")
    os.remove(db)
    os.exit(1)
  end
end

os.remove(db)
io.write("schema ok\n")
os.exit(0)
