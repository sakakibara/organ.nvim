-- Emacs `org-id-locations-file` export.  Format mirrors
-- `org-id-hash-to-alist`'s s-expression output:
--
--   ((FILE_PATH ID1 ID2 ...) (FILE_PATH2 ID3 ...))
--
-- Round-trip: Emacs's org-id-locations-load reads this and populates
-- its hash so cross-file `[[id:...]]` resolution works without a
-- full scan.
--
-- Run via: nvim --headless -l tests/id_locations_export_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Two files, three IDs (one file has two headlines with IDs).
do
  local f1 = io.open(org_dir .. "/notes.org", "w")
  f1:write([==[
* Alpha
  :PROPERTIES:
  :ID:       11111111-1111-1111-1111-111111111111
  :END:

* Beta
  :PROPERTIES:
  :ID:       22222222-2222-2222-2222-222222222222
  :END:
]==])
  f1:close()
end
do
  local f2 = io.open(org_dir .. "/other.org", "w")
  f2:write([==[
* Gamma
  :PROPERTIES:
  :ID:       33333333-3333-3333-3333-333333333333
  :END:
]==])
  f2:close()
end

require("organ").setup({
  db_path = tmp .. "/idx.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  links = { id_locations_file = tmp .. "/.org-id-locations" },
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

local id = require("organ.id")

-- ---------------------------------------------------------------------------
-- (a) Explicit export: write to a target path, content is parseable
--     s-expr alist with the expected ID strings.
-- ---------------------------------------------------------------------------
local target = tmp .. "/explicit.locations"
local path, n = id.export_locations(target)
check("export returns the written path", path == target, tostring(path))
check("export returns 2 file groups", n == 2, "got " .. tostring(n))

local f = assert(io.open(target, "r"))
local body = f:read("*a")
f:close()

check("header comment present", body:find(";; %-%*%- coding: utf%-8 %-%*%-") ~= nil, body)
check("alist top-level open paren", body:find("\n%(\n") ~= nil or body:find("^[^\n]*\n%(") ~= nil)
check(
  "notes.org appears as a quoted absolute path",
  body:find('"' .. org_dir .. "/notes.org" .. '"', 1, true) ~= nil
)
check(
  "other.org appears as a quoted absolute path",
  body:find('"' .. org_dir .. "/other.org" .. '"', 1, true) ~= nil
)
for _, uuid in ipairs({
  "11111111-1111-1111-1111-111111111111",
  "22222222-2222-2222-2222-222222222222",
  "33333333-3333-3333-3333-333333333333",
}) do
  check("uuid present in export: " .. uuid, body:find('"' .. uuid .. '"', 1, true) ~= nil)
end
check(
  "notes.org row has BOTH IDs in one parenthesised group",
  body:find('%("' .. org_dir .. '/notes%.org" "1', nil) ~= nil
    and body:find('"22222222', 1, true) ~= nil,
  body
)

-- ---------------------------------------------------------------------------
-- (b) Auto-export hook fires after scan_done when id_locations_file
--     is set in config.
-- ---------------------------------------------------------------------------
local auto_target = tmp .. "/.org-id-locations"
require("organ.id")._maybe_auto_export()
local af = assert(io.open(auto_target, "r"))
local auto_body = af:read("*a")
af:close()
check(
  "auto-export wrote to configured id_locations_file",
  auto_body:find("11111111", 1, true) ~= nil
)

-- ---------------------------------------------------------------------------
-- (c) No id_locations_file configured → export returns nil + error msg.
-- ---------------------------------------------------------------------------
require("organ").config.links.id_locations_file = nil
local p2, err = id.export_locations()
check("nil id_locations_file: returns nil", p2 == nil)
check(
  "nil id_locations_file: error mentions configuration",
  type(err) == "string" and err:find("configured", 1, true) ~= nil,
  tostring(err)
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("id_locations_export_test: PASS")
