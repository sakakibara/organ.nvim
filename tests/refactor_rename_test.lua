-- Headline rename refactoring: plan + apply.
-- Run via: nvim --headless -l tests/refactor_rename_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname() .. "/refactor"
vim.fn.mkdir(tmp, "p")

local file_a = tmp .. "/a.org"
local file_b = tmp .. "/b.org"

vim.fn.writefile({
  "* TODO Original :work:",
  "  body line",
}, file_a)

vim.fn.writefile({
  "* TODO Caller",
  "  See [[*Original][the source]] and [[*Original]] and [[id:abc][bytes]].",
  "* DONE Other",
  "  Mentions [[*Other thing]] not relevant.",
}, file_b)

package.loaded["organ.query"] = {
  agenda = function()
    return {}
  end,
  headlines = function()
    return {}
  end,
  files = function()
    return { { file_path = file_a }, { file_path = file_b } }
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local refactor = require("organ.refactor")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. Plan: locate headline-line edit + 2 link edits in b.org.
local target = { id = "id-target", title = "Original", file_path = file_a, line_start = 0 }
local edits, err = refactor.plan(target, "Renamed")
check("plan: returns edits without error", edits ~= nil and err == nil)
check(
  "plan: 1 edit on a.org",
  (function()
    local n = 0
    for _, e in ipairs(edits) do
      if e.path == file_a then
        n = n + 1
      end
    end
    return n == 1
  end)()
)
check(
  "plan: 2 edits on b.org (both *Original links)",
  (function()
    local n = 0
    for _, e in ipairs(edits) do
      if e.path == file_b then
        n = n + 1
      end
    end
    return n == 2
  end)(),
  "edits: " .. vim.inspect(edits)
)

-- 2. Plan: empty new_name → error.
local _, err2 = refactor.plan(target, "")
check("plan: empty new_name returns error", err2 ~= nil)

-- 3. Apply: file contents reflect new title + updated links.
refactor.apply(edits)

local a_lines = vim.fn.readfile(file_a)
check(
  "apply: a.org headline rewritten",
  a_lines[1]:find("Renamed", 1, true) ~= nil and not a_lines[1]:find("Original", 1, true),
  "got: " .. a_lines[1]
)
check("apply: a.org TODO state preserved", a_lines[1]:find("TODO", 1, true) ~= nil)
check("apply: a.org tag preserved", a_lines[1]:find(":work:", 1, true) ~= nil)

local b_lines = vim.fn.readfile(file_b)
check(
  "apply: b.org [[*Original][the source]] → [[*Renamed][the source]]",
  b_lines[2]:find("[[*Renamed][the source]]", 1, true) ~= nil,
  "got: " .. b_lines[2]
)
check(
  "apply: b.org [[*Original]] → [[*Renamed]]",
  (function()
    local _, n = b_lines[2]:gsub("%[%[%*Renamed%]%]", "")
    return n == 1
  end)()
)
check("apply: b.org [[id:abc]] untouched", b_lines[2]:find("[[id:abc][bytes]]", 1, true) ~= nil)
check("apply: b.org *Other thing untouched", b_lines[4]:find("[[*Other thing]]", 1, true) ~= nil)

-- 4. End-to-end: a second rename now operates on the new title.
local target2 = { id = "id-target", title = "Renamed", file_path = file_a, line_start = 0 }
local edits2 = refactor.plan(target2, "Final")
refactor.apply(edits2)
local a2 = vim.fn.readfile(file_a)
check("second rename: a.org now reads 'Final'", a2[1]:find("Final", 1, true) ~= nil)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("refactor_rename_test: PASS")
