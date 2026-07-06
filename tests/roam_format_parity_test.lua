-- Top-of-file format parity for roam nodes and dailies, ground-truthed
-- against the actual org-roam package (org-roam 20260425, org 9.7.11):
--
--   node file: <YYYYMMDDHHMMSS>-<slug>.org
--     :PROPERTIES:
--     :ID:       <uuid>
--     :END:
--     #+title: <title>
--
--   daily file: daily/<YYYY-MM-DD>.org -- same header, plus the `* `
--     heading that org-roam's default daily capture (`entry "* %?"`)
--     seeds.
--
-- The 7 spaces after `:ID:` are not arbitrary: Emacs `org-property-format`
-- ("%-10s %s") pads the `:ID:` key to 10 columns then adds one space.
-- UUID method mirrors Emacs `org-id-method` via `links.id_method`: organ
-- defaults to "uuid" (v7, time-ordered); "uuidv4" reproduces Emacs's
-- default random uuid.
--
-- Run via: nvim --headless -l tests/roam_format_parity_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n      " .. tostring(detail)) or ""))
  end
end

local V4 = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local V7 = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- 1. uuid.v4 -- Emacs org-id default (`org-id-method` = uuid = v4 random)
local uuid = require("organ.uuid")
do
  local id = uuid.v4()
  check("v4 shape", id:match(V4) ~= nil, id)
  check("v4 lowercase", id == id:lower(), id)
  check("v4 distinct draws", uuid.v4() ~= uuid.v4())
  check("v7 still v7 shape", uuid.v7():match(V7) ~= nil)
end

-- 2. note.header -- shared file-level :ID: drawer + #+title
local note = require("organ.roam.note")
do
  local lines = note.header("THE-ID", "My Title")
  check("header line 1 is :PROPERTIES:", lines[1] == ":PROPERTIES:", lines[1])
  check("header :ID: padded to 7 spaces", lines[2] == ":ID:       THE-ID", "[" .. lines[2] .. "]")
  check(
    "header :ID: prefix is exactly 11 cols",
    lines[2]:sub(1, 11) == ":ID:       ",
    "[" .. lines[2]:sub(1, 11) .. "]"
  )
  check("header line 3 is :END:", lines[3] == ":END:", lines[3])
  check("header #+title one space", lines[4] == "#+title: My Title", lines[4])
  check("header has no trailing blank", #lines == 4, "#lines=" .. #lines)
end

-- 3. id.generate honors `links.id_method` (the single org-id-method analog)
do
  local idgen = require("organ.id")
  local bc = require("organ.buf_config")
  bc.set(0, "links.id_method", "uuidv4")
  check("generate 'uuidv4' -> v4", (idgen.generate(0) or ""):match(V4) ~= nil)
  bc.set(0, "links.id_method", "uuid")
  check("generate 'uuid' -> v7", (idgen.generate(0) or ""):match(V7) ~= nil)
  bc.unset(0, "links.id_method")
  check("generate default -> v7", (idgen.generate(0) or ""):match(V7) ~= nil)
end

local function setup(extra)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local opts = vim.tbl_deep_extend("force", {
    org_dir = tmp,
    db_path = tmp .. "/x.db",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
    roam = { dir = tmp .. "/roam" },
  }, extra or {})
  require("organ").setup(opts)
  return tmp, tmp .. "/roam"
end

-- 4. Node buffer: exact 4-line header, default id is v7, no trailing blank.
--    A new node opens unsaved, so the content lives in the buffer.
do
  setup()
  require("organ.roam").create_node("Hello World!")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("node: :PROPERTIES: first", lines[1] == ":PROPERTIES:", lines[1])
  check(
    "node: :ID: 7-space + v7",
    (lines[2] or ""):match("^:ID:       " .. V7:sub(2)) ~= nil,
    lines[2]
  )
  check("node: :END:", lines[3] == ":END:")
  check("node: #+title raw", lines[4] == "#+title: Hello World!", lines[4])
  check("node: no trailing blank lines (exactly 4)", #lines == 4, "#lines=" .. #lines)
end

-- 5. Daily buffer: header + the `* ` heading org-roam seeds, no extra
--    blank.  A new daily opens unsaved, so the content lives in the buffer.
--    (Runs before any uuidv4 setup so the default v7 isn't masked by
--    setup()'s cumulative config merge.)
do
  setup()
  require("organ.roam.dailies").for_date("2026-06-17")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("daily: :PROPERTIES: first", lines[1] == ":PROPERTIES:")
  check(
    "daily: :ID: 7-space + v7",
    (lines[2] or ""):match("^:ID:       " .. V7:sub(2)) ~= nil,
    lines[2]
  )
  check("daily: :END:", lines[3] == ":END:")
  check("daily: #+title is the iso date", lines[4] == "#+title: 2026-06-17", lines[4])
  check("daily: seeds a '* ' heading", lines[5] == "* ", "[" .. tostring(lines[5]) .. "]")
  check("daily: exactly 5 lines (no trailing blank)", #lines == 5, "#lines=" .. #lines)
end

-- 6. Node with links.id_method = "uuidv4" -> an Emacs-default-shaped id.
do
  setup({ links = { id_method = "uuidv4" } })
  require("organ.roam").create_node("V Four")
  local id = (vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] or ""):match("^:ID:%s+(%S+)")
  check("node uuidv4: id is v4 shape", (id or ""):match(V4) ~= nil, id)
end

-- 7. Daily with links.id_method = "uuidv4".
do
  setup({ links = { id_method = "uuidv4" } })
  require("organ.roam.dailies").for_date("2027-01-02")
  local id = (vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] or ""):match("^:ID:%s+(%S+)")
  check("daily uuidv4: id is v4 shape", (id or ""):match(V4) ~= nil, id)
end

if fails > 0 then
  io.write(("FAILED %d checks\n"):format(fails))
  os.exit(1)
end
io.write("roam format parity ok\n")
os.exit(0)
