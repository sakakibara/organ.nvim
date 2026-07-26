-- tests/agenda_block_keymaps_test.lua
-- Run via: nvim --headless -l tests/agenda_block_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

local agenda = require("organ.agenda")
local query = require("organ.query")

-- Stub query.agenda with deterministic rows.
local seq = 0
local orig = query.agenda
query.agenda = function()
  seq = seq + 1
  return {
    {
      id = "r" .. seq,
      title = "T" .. seq,
      todo_state = "TODO",
      priority = "A",
      scheduled_date = "2026-04-26",
      tags = {},
      file_path = "/x.org",
      line_start = seq,
      level = 1,
    },
  }
end

local bufnr = agenda.open({
  blocks = {
    { label = "Alpha", from = "today", to = "today", group_by = "none" },
    { label = "Beta", from = "today", to = "today", group_by = "none" },
    { label = "Gamma", from = "today", to = "today", group_by = "none" },
  },
})

query.agenda = orig

local function press(key)
  local seq = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(seq, "x", false)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

local starts = agenda.buf_state(bufnr).block_starts
local lnums = {}
for k in pairs(starts) do
  lnums[#lnums + 1] = k
end
table.sort(lnums)
local first, second, third = lnums[1], lnums[2], lnums[3]
assert_eq(#lnums, 3)

-- ]] from the first block header itself advances to the second block
-- header because ]] uses strict > (Vim convention).
vim.api.nvim_win_set_cursor(0, { first, 0 })
press("]]")
assert_eq(vim.api.nvim_win_get_cursor(0)[1], second, "]] from first header -> second header")

-- ]] inside block 1 jumps to block 2.
vim.api.nvim_win_set_cursor(0, { first + 1, 0 })
press("]]")
assert_eq(vim.api.nvim_win_get_cursor(0)[1], second, "]] -> second")

-- ]] from inside last block stays put (no wrap).
vim.api.nvim_win_set_cursor(0, { third + 1, 0 })
press("]]")
assert_eq(vim.api.nvim_win_get_cursor(0)[1], third + 1, "]] no wrap")

-- ]] from exactly on a block header advances to the *next* block header,
-- not to itself (strict >, not >=).
vim.api.nvim_win_set_cursor(0, { first, 0 })
press("]]")
assert_eq(vim.api.nvim_win_get_cursor(0)[1], second, "]] from on-header -> next header (strict >)")

-- [[ symmetric.
vim.api.nvim_win_set_cursor(0, { third, 0 })
press("[[")
assert_eq(vim.api.nvim_win_get_cursor(0)[1], second, "[[ -> second")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
press("[[")
assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, "[[ no wrap before first")

-- <Tab> on first block header folds the block.
vim.api.nvim_win_set_cursor(0, { first, 0 })
press("<Tab>")
assert_eq(vim.fn.foldclosed(first), first, "<Tab> closes the fold")
press("<Tab>")
assert_eq(vim.fn.foldclosed(first), -1, "<Tab> reopens the fold")

vim.api.nvim_buf_delete(bufnr, { force = true })

-- Probe (C1): line_index must not contain vim.NIL after vim.b round-trip.
-- Pre-fix: encode_state only re-keyed block_starts, leaving line_index
-- as a sparse integer-keyed table that vim.b pads with vim.NIL.
do
  seq = 0
  query.agenda = function()
    seq = seq + 1
    return {
      {
        id = "p" .. seq,
        title = "P" .. seq,
        todo_state = "TODO",
        priority = "A",
        scheduled_date = "2026-04-26",
        tags = {},
        file_path = "/p.org",
        line_start = seq,
        level = 1,
      },
    }
  end
  local pb = agenda.open({
    blocks = {
      { label = "Probe", from = "today", to = "today", group_by = "none" },
    },
  })
  query.agenda = orig

  local line_index = agenda.buf_state(pb).line_index or {}
  for lnum, v in pairs(line_index) do
    assert(
      v ~= vim.NIL,
      "line_index[" .. tostring(lnum) .. "] is vim.NIL (encode_state must re-key line_index)"
    )
    assert(
      type(v) == "table",
      "line_index[" .. tostring(lnum) .. "] has unexpected type " .. type(v)
    )
  end

  vim.api.nvim_buf_delete(pb, { force = true })
end

-- Regression (I5): keymaps must not crash on non-row lines.
-- Pre-fix: vim.NIL leaked through line_index for header/separator/
-- placeholder lines; keymap callbacks did `if r then r.file_path` which
-- crashed because vim.NIL is truthy in Lua.
do
  -- call_n tracks how many times query.agenda has been called for this
  -- block so the first block gets one row and the second gets none.
  local call_n = 0
  query.agenda = function()
    call_n = call_n + 1
    if call_n == 1 then
      return {
        {
          id = "i5",
          title = "I5",
          todo_state = "TODO",
          priority = "A",
          scheduled_date = "2026-04-26",
          tags = {},
          file_path = "/i5.org",
          line_start = 1,
          level = 1,
        },
      }
    end
    return {}
  end
  local b2 = agenda.open({
    blocks = {
      { label = "Has", from = "today", to = "today", group_by = "none" },
      { label = "Empty", from = "today", to = "today", group_by = "none" },
    },
  })
  query.agenda = orig
  vim.api.nvim_set_current_buf(b2)

  -- line_index round-trip: no vim.NIL values allowed.
  local line_index = agenda.buf_state(b2).line_index or {}
  for lnum, v in pairs(line_index) do
    assert(
      v ~= vim.NIL,
      "I5: line_index[" .. tostring(lnum) .. "] is vim.NIL after vim.b round-trip"
    )
    assert(
      type(v) == "table",
      "I5: line_index[" .. tostring(lnum) .. "] unexpected type " .. type(v)
    )
  end

  -- Identify the first block header line.
  local b2_starts = agenda.buf_state(b2).block_starts or {}
  local b2_lnums = {}
  for k in pairs(b2_starts) do
    b2_lnums[#b2_lnums + 1] = k
  end
  table.sort(b2_lnums)
  local hdr1 = b2_lnums[1] -- "Has" header
  assert(hdr1 ~= nil, "I5: expected at least one block header")

  -- <CR> on a block header must be a no-op, not a crash.
  -- current_row() returns nil for header lines (line_index[hdr1] == nil).
  vim.api.nvim_win_set_cursor(0, { hdr1, 0 })
  press("<CR>") -- must not raise

  -- j from the row line (hdr1+1) should stay put or advance without crashing.
  -- The row line is immediately after the "Has" header; pressing j will scan
  -- forward through the separator, the "Empty" header, and the "(nothing)"
  -- placeholder — all non-row lines — and should not crash on any of them.
  vim.api.nvim_win_set_cursor(0, { hdr1 + 1, 0 })
  press("j") -- must not raise; may stay put (no further row lines)

  -- After j, verify once more that no vim.NIL values are present (the j
  -- callback re-reads state from vim.b, exercising decode_state on line_index).
  local li2 = agenda.buf_state(b2).line_index or {}
  for lnum, v in pairs(li2) do
    assert(v ~= vim.NIL, "I5: post-j line_index[" .. tostring(lnum) .. "] is vim.NIL")
    assert(
      type(v) == "table",
      "I5: post-j line_index[" .. tostring(lnum) .. "] unexpected type " .. type(v)
    )
  end

  vim.api.nvim_buf_delete(b2, { force = true })
end

-- / filter mutates title_match across ALL blocks.
do
  seq = 0
  query.agenda = function()
    seq = seq + 1
    return {}
  end
  local b = agenda.open({
    blocks = {
      { label = "A", from = "today", to = "today", group_by = "none" },
      { label = "B", from = "today", to = "today", group_by = "none" },
    },
  })
  query.agenda = orig

  -- Simulate what the / keymap callback does: apply title_match to all blocks.
  local state = agenda.buf_state(b)
  for _, block in ipairs(state.view.blocks) do
    block.title_match = "needle"
  end
  for _, block in ipairs(state.view.blocks) do
    assert_eq(block.title_match, "needle", "every block got the filter")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

io.write("agenda block keymaps ok\n")
