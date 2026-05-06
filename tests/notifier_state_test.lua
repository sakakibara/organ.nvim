-- Verifies organ.notifier.state JSON roundtrip + atomic write.
-- Run: nvim --headless -l tests/notifier_state_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Redirect stdpath("data") to a tempdir so we don't touch the user's real
-- state file. nvim allows overriding via XDG_DATA_HOME at startup but not
-- mid-run, so monkey-patch vim.fn.stdpath instead.
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local orig_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
  if what == "data" then
    return tmpdir
  end
  return orig_stdpath(what)
end

local state = require("organ.notifier.state")

-- 1. Path lives under our tempdir.
local path = state.path()
assert(path:sub(1, #tmpdir) == tmpdir, "state path under tempdir, got " .. path)
assert(path:sub(-26) == "/organ/notifier-state.json", "state filename: " .. path)

-- 2. load() on missing file returns the empty default.
local s = state.load()
assert(type(s) == "table", "load returns table")
assert(s.entries and #s.entries == 0, "empty entries by default")
assert(s.version == 1, "schema version 1")

-- 3. save() + load() roundtrips entries faithfully.
local entries = {
  { id = "a|100|0", at = 1735689600, title = "Standup", body = "Standup in 0", handle = "h-1" },
  { id = "b|200|10", at = 1735693200, title = "Review", body = "Review in 10", handle = "h-2" },
}
assert(state.set_entries(entries, "linux"), "set_entries succeeds")
local loaded = state.load()
assert(loaded.platform == "linux", "platform persisted")
assert(#loaded.entries == 2, "two entries persisted")
assert(loaded.entries[1].id == "a|100|0", "entry 1 id roundtrip")
assert(loaded.entries[2].handle == "h-2", "entry 2 handle roundtrip")
assert(loaded.entries[1].at == 1735689600, "timestamps preserved")

-- 4. set_entries replaces the whole batch (no merge).
assert(state.set_entries({}, "linux"), "set_entries with empty list")
local empty = state.load()
assert(#empty.entries == 0, "previous entries removed")

-- 5. Atomic write — temp file should not linger after success.
state.set_entries(entries, "macos")
assert(vim.fn.filereadable(state.path() .. ".tmp") == 0, "no leftover .tmp file")

-- 6. Corrupt state file — load() falls back to empty rather than crashing.
local fd = assert(io.open(state.path(), "w"))
fd:write("{ this is not valid json")
fd:close()
local fb = state.load()
assert(type(fb) == "table" and #fb.entries == 0, "corrupted file → empty default")

vim.fn.delete(tmpdir, "rf")
print("notifier_state_test: PASS")
os.exit(0)
