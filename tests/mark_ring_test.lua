-- organ.mark_ring: `:Org mark_ring push` / `:Org mark_ring goto`
-- (Emacs org-mark-ring-push / org-mark-ring-goto, C-c % and C-c &).
--
-- Emacs keeps a circular ring of `org-mark-ring-length` positions:
-- pushing rotates it so the new position is the head, and repeated
-- gotos walk deeper into the ring rather than bouncing on the head.
-- organ keeps that ring AND feeds Neovim's jumplist on every push, so
-- `<C-o>` keeps working.
--
-- Run via: nvim --headless -l tests/mark_ring_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local mark_ring = require("organ.mark_ring")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function tmp_org(lines)
  local path = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, path)
  return path
end

local A = tmp_org({ "* A1", "* A2", "* A3", "* A4", "* A5", "* A6" })
local B = tmp_org({ "* B1", "* B2", "* B3" })

-- 1. An empty ring has nothing to go back to.
mark_ring.clear()
do
  local entry, why = mark_ring.goto_mark()
  check("an empty ring refuses", entry == nil and why == "org mark ring is empty", tostring(why))
end

-- 2. Push records the cursor position; goto returns to it.
do
  vim.cmd("edit " .. vim.fn.fnameescape(A))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local pushed = mark_ring.push()
  check("push records the cursor line", pushed ~= nil and pushed.line == 3, vim.inspect(pushed))
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  mark_ring.goto_mark()
  check("goto returns to the pushed line", vim.api.nvim_win_get_cursor(0)[1] == 3)
end

-- 3. Consecutive gotos walk deeper into the ring.
mark_ring.clear()
do
  vim.cmd("edit " .. vim.fn.fnameescape(A))
  for _, l in ipairs({ 2, 4, 6 }) do
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    mark_ring.push()
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  mark_ring.goto_mark()
  local first = vim.api.nvim_win_get_cursor(0)[1]
  mark_ring.goto_mark()
  local second = vim.api.nvim_win_get_cursor(0)[1]
  mark_ring.goto_mark()
  local third = vim.api.nvim_win_get_cursor(0)[1]
  check(
    "repeated gotos walk the ring newest-first",
    first == 6 and second == 4 and third == 2,
    ("%d %d %d"):format(first, second, third)
  )
  mark_ring.goto_mark()
  check("the walk wraps around", vim.api.nvim_win_get_cursor(0)[1] == 6)
end

-- 4. A push resets the walk to the head.
do
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  mark_ring.push()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  mark_ring.goto_mark()
  check("a push restarts the walk at the new head", vim.api.nvim_win_get_cursor(0)[1] == 5)
end

-- 5. The ring is bounded by `mark_ring.length`; the oldest drops off.
mark_ring.clear()
do
  require("organ.buf_config").set(0, "mark_ring.length", 2)
  vim.cmd("edit " .. vim.fn.fnameescape(A))
  for _, l in ipairs({ 1, 2, 3 }) do
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    mark_ring.push()
  end
  check("the ring holds only `length` entries", #mark_ring._ring == 2, tostring(#mark_ring._ring))
  local lines = { mark_ring._ring[1].line, mark_ring._ring[2].line }
  check(
    "the oldest entry drops off",
    lines[1] == 3 and lines[2] == 2,
    ("%d %d"):format(lines[1], lines[2])
  )
  require("organ.buf_config").unset(0, "mark_ring.length")
end

-- 6. The ring spans files: a goto reopens the file it recorded.
mark_ring.clear()
do
  vim.cmd("edit " .. vim.fn.fnameescape(A))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  mark_ring.push()
  vim.cmd("edit " .. vim.fn.fnameescape(B))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  mark_ring.goto_mark()
  check(
    "goto crosses back into the other file",
    vim.api.nvim_buf_get_name(0) == vim.fn.resolve(A)
      or vim.api.nvim_buf_get_name(0):match("[^/]+$") == A:match("[^/]+$"),
    vim.api.nvim_buf_get_name(0)
  )
  check("and lands on the recorded line", vim.api.nvim_win_get_cursor(0)[1] == 2)
end

-- 7. A stale line number is clamped rather than raising.
mark_ring.clear()
do
  local path = tmp_org({ "* one", "* two", "* three", "* four" })
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  mark_ring.push()
  vim.api.nvim_buf_set_lines(0, 1, -1, false, {})
  local entry = mark_ring.goto_mark()
  check(
    "a shrunken file clamps the jump",
    entry ~= nil and vim.api.nvim_win_get_cursor(0)[1] == 1,
    vim.inspect(vim.api.nvim_win_get_cursor(0))
  )
end

-- 8. Following a link records where the jump started, so the ring is
-- useful without an explicit push.
mark_ring.clear()
do
  local target = tmp_org({ "* Target heading", "body" })
  local source = tmp_org({ "* Source", ("[[file:%s]]"):format(target) })
  vim.cmd("edit " .. vim.fn.fnameescape(source))
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  pcall(function()
    require("organ.link").follow()
  end)
  check(
    "following a link pushes the origin",
    #mark_ring._ring == 1 and mark_ring._ring[1].line == 2,
    vim.inspect(mark_ring._ring)
  )
end

-- 9. A buffer with no file cannot be marked.
mark_ring.clear()
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  local entry, why = mark_ring.push()
  check(
    "a scratch buffer refuses",
    entry == nil and why == "cannot mark a buffer with no file",
    tostring(why)
  )
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nmark_ring: all checks passed")
