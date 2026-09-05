-- organ.list.cycle_bullet: `:Org list cycle_bullet` (Emacs
-- org-cycle-list-bullet, reached through C-c - on an item).  Every
-- expectation is the buffer real Emacs 30 / org 9.7.11 produces, checked
-- with
--   emacs --batch -Q -l org --eval '(org-cycle-list-bullet)'
-- before it was encoded here.
--
-- Run via: nvim --headless -l tests/list_cycle_bullet_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local list = require("organ.list")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- Cycle `n` times from `line` and compare the whole buffer.
local function cycled(label, lines, line, n, which, want)
  local b = mkbuf(lines)
  local last, why
  for _ = 1, n do
    last, why = list.cycle_bullet(b, line, which)
    if not last then
      break
    end
  end
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(label, last ~= nil and vim.deep_equal(got, want), why or table.concat(got, " | "))
end

-- 1. At column 0 the `*` bullet is skipped -- an unindented `*` is a
-- headline -- so the cycle is `-` `+` `1.` `1)`.
local FLAT = { "- a", "- b", "- c" }
cycled("col-0 step 1 gives +", FLAT, 1, 1, nil, { "+ a", "+ b", "+ c" })
cycled("col-0 step 2 gives 1.", FLAT, 1, 2, nil, { "1. a", "2. b", "3. c" })
cycled("col-0 step 3 gives 1)", FLAT, 1, 3, nil, { "1) a", "2) b", "3) c" })
cycled("col-0 step 4 wraps to -", FLAT, 1, 4, nil, { "- a", "- b", "- c" })

-- 2. Indented, `*` joins the cycle.
local NESTED = { "* H", "  - a", "  - b" }
cycled("indented step 1 gives +", NESTED, 2, 1, nil, { "* H", "  + a", "  + b" })
cycled("indented step 2 gives *", NESTED, 2, 2, nil, { "* H", "  * a", "  * b" })
cycled("indented step 3 gives 1.", NESTED, 2, 3, nil, { "* H", "  1. a", "  2. b" })
cycled("indented step 4 gives 1)", NESTED, 2, 4, nil, { "* H", "  1) a", "  2) b" })
cycled("indented step 5 wraps to -", NESTED, 2, 5, nil, { "* H", "  - a", "  - b" })

-- 3. A description item cannot be numbered, so its cycle is only the
-- unordered bullets.
local DESC = { "  - term :: def", "  - t2 :: d2" }
cycled("description step 1 gives +", DESC, 1, 1, nil, { "  + term :: def", "  + t2 :: d2" })
cycled("description step 2 gives *", DESC, 1, 2, nil, { "  * term :: def", "  * t2 :: d2" })
cycled("description step 3 wraps to -", DESC, 1, 3, nil, { "  - term :: def", "  - t2 :: d2" })

-- 4. Only the sub-list holding the cursor changes.
cycled(
  "a nested list cycles alone",
  { "- a", "  - x", "  - y", "- b" },
  2,
  1,
  nil,
  { "- a", "  + x", "  + y", "- b" }
)

-- 5. `previous` walks the cycle the other way.
cycled("previous steps backwards", { "- a", "- b" }, 1, 1, "previous", { "1) a", "2) b" })

-- 6. An explicit bullet is used directly; one the context forbids is
-- refused.
cycled("an explicit bullet is applied", { "- a", "- b" }, 1, 1, "1.", { "1. a", "2. b" })
do
  local b = mkbuf({ "- a", "- b" })
  local new, why = list.cycle_bullet(b, 1, "*")
  check(
    "`*` is refused at column 0",
    new == nil
      and why == "not an allowed bullet here: *"
      and vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "- a", "- b" }),
    tostring(why)
  )
end

-- 7. Off an item, Emacs errors "Not at an item"; organ reports and
-- leaves the buffer alone.
do
  local b = mkbuf({ "plain text" })
  local new, why = list.cycle_bullet(b, 1)
  check(
    "off an item it refuses",
    new == nil
      and why == "not at an item"
      and vim.api.nvim_buf_get_lines(b, 0, -1, false)[1] == "plain text",
    tostring(why)
  )
end

-- 8. Going ordered and back restores the original bullets.
do
  local before = { "  - alpha", "  - bravo", "  - charlie" }
  local b = mkbuf(before)
  for _ = 1, 5 do
    list.cycle_bullet(b, 1)
  end
  check(
    "a full cycle restores the list",
    vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), before),
    table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " | ")
  )
end

-- 9. A long list cycles in bounded time.
do
  local lines = {}
  for i = 1, 2000 do
    lines[i] = ("- item %d"):format(i)
  end
  local b = mkbuf(lines)
  local started = vim.uv.hrtime()
  local new = list.cycle_bullet(b, 1)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("2000 items cycle", new == "+" and got[1] == "+ item 1" and got[2000] == "+ item 2000")
  check("2000 items cycle inside 5s", elapsed < 5000, ("%.0fms"):format(elapsed))
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nlist_cycle_bullet: all checks passed")
