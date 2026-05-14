-- meta_return.dispatch (the action behind `:Org meta_return` and
-- <M-CR> on a headline) inserts a new sibling headline.  After this
-- test, the inserted heading's blank-line surroundings match the
-- buffer's existing pattern via organ.spacing.
--
-- Run via: nvim --headless -l tests/meta_return_spacing_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local meta_return = require("organ.meta_return")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- (a) Tight buffer (no blanks): new heading inserted tight.
do
  local b = buf_with({
    "* H1",
    "body 1",
    "* H2",
    "body 2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on H1
  meta_return.dispatch({ enter_insert = false })
  local got = lines_of(b)
  check(
    "tight style: new heading inserted with 0 blanks above",
    got[3] == "* " or got[4] == "* ",
    table.concat(got, "|")
  )
  -- Detect blank count above the new heading.
  local new_line
  for i, l in ipairs(got) do
    if l == "* " then
      new_line = i
      break
    end
  end
  local blanks_above = 0
  if new_line then
    for i = new_line - 1, 1, -1 do
      if got[i] == "" then
        blanks_above = blanks_above + 1
      else
        break
      end
    end
  end
  check("tight style: 0 blank lines above new heading", blanks_above == 0, "got=" .. blanks_above)
end

-- (b) Blank-above style: new heading inherits 1 blank above.
do
  local b = buf_with({
    "preamble",
    "",
    "* H1",
    "body",
    "",
    "* H2",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- on H1
  meta_return.dispatch({ enter_insert = false })
  local got = lines_of(b)
  -- The new heading should be inserted after H1's body (line 4) with
  -- 1 blank line above it (matching the buffer pattern).
  local new_line
  for i, l in ipairs(got) do
    if i > 4 and l == "* " then
      new_line = i
      break
    end
  end
  check("blank-above style: new heading inserted", new_line ~= nil, table.concat(got, "|"))
  if new_line then
    local blanks_above = 0
    for i = new_line - 1, 1, -1 do
      if got[i] == "" then
        blanks_above = blanks_above + 1
      else
        break
      end
    end
    check(
      "blank-above style: 1 blank line above new heading",
      blanks_above == 1,
      "got=" .. blanks_above .. " buf=" .. table.concat(got, "|")
    )
  end
end

-- (c) Two-blank style preserved.
do
  local b = buf_with({
    "preamble",
    "",
    "",
    "* H1",
    "body",
    "",
    "",
    "* H2",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- on H1
  meta_return.dispatch({ enter_insert = false })
  local got = lines_of(b)
  -- Find the new heading -- the LAST instance of "* " (the new one)
  -- since the original H1 is still "* H1".
  local new_line
  for i = #got, 1, -1 do
    if got[i] == "* " then
      new_line = i
      break
    end
  end
  check("two-blank style: new heading inserted", new_line ~= nil, table.concat(got, "|"))
  if new_line then
    local blanks_above = 0
    for i = new_line - 1, 1, -1 do
      if got[i] == "" then
        blanks_above = blanks_above + 1
      else
        break
      end
    end
    check(
      "two-blank style: 2 blank lines above new heading",
      blanks_above == 2,
      "got=" .. blanks_above .. " buf=" .. table.concat(got, "|")
    )
  end
end

-- (d) Explicit policy override via config.
do
  require("organ").config.structure = require("organ").config.structure or {}
  require("organ").config.structure.headline_spacing = "both"
  local b = buf_with({
    "* H1",
    "body",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  meta_return.dispatch({ enter_insert = false })
  local got = lines_of(b)
  local new_line
  for i = #got, 1, -1 do
    if got[i] == "* " then
      new_line = i
      break
    end
  end
  check("explicit policy 'both' overrides auto-detect", new_line ~= nil)
  if new_line then
    local blanks_above = 0
    for i = new_line - 1, 1, -1 do
      if got[i] == "" then
        blanks_above = blanks_above + 1
      else
        break
      end
    end
    check(
      "explicit 'both': 1 blank line above (forced even though buffer has none)",
      blanks_above == 1,
      "got=" .. blanks_above .. " buf=" .. table.concat(got, "|")
    )
  end
  require("organ").config.structure.headline_spacing = nil
end

-- (e) Blank-above style: the next sibling must keep its own blank-
-- above after the insert.  Visually this means the new heading sees
-- a blank ABOVE AND a blank BELOW (the latter is the next sibling's
-- before-blank, not the new heading's after).  Without re-normalizing
-- the following heading, the new one "steals" the blank and the
-- sibling renders flush against it.
do
  local b = buf_with({
    "* H1",
    "body 1",
    "",
    "* H2",
    "body 2",
    "",
    "* H3",
    "body 3",
  })
  vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- on H2
  meta_return.dispatch({ enter_insert = false })
  local got = lines_of(b)
  -- New heading is the empty "* " line; locate it.
  local new_line
  for i, l in ipairs(got) do
    if l == "* " then
      new_line = i
      break
    end
  end
  check(
    "blank-above style + next sibling: new heading inserted",
    new_line ~= nil,
    table.concat(got, "|")
  )
  if new_line then
    local blanks_above = 0
    for i = new_line - 1, 1, -1 do
      if got[i] == "" then
        blanks_above = blanks_above + 1
      else
        break
      end
    end
    local blanks_below = 0
    for i = new_line + 1, #got do
      if got[i] == "" then
        blanks_below = blanks_below + 1
      else
        break
      end
    end
    check(
      "blank-above style: 1 blank above new heading",
      blanks_above == 1,
      "got=" .. blanks_above .. " buf=" .. table.concat(got, "|")
    )
    check(
      "blank-above style: 1 blank between new heading and next sibling (sibling's own before-blank)",
      blanks_below == 1,
      "got=" .. blanks_below .. " buf=" .. table.concat(got, "|")
    )
  end
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("meta_return_spacing_test: PASS")
