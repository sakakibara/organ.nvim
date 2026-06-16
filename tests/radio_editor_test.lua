-- Editor radio: definitions cache.
-- Run via: nvim --headless -l tests/radio_editor_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local radio = require("organ.radio")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  return b
end

-- collect defs: normalized phrases + first-occurrence positions.
do
  local b = mkbuf({
    "Define <<<my phrase>>> here.",
    "Another <<<My Phrase>>> dup and <<<lead>>>.",
  })
  local t = radio.targets(b)
  check(#t.phrases == 2, "cache: two distinct phrases (case-insensitive dedupe)")
  check(t.phrases[1] == "my phrase", "cache: longest-first")
  check(t.defs["my phrase"].line == 1, "cache: first definition line recorded")
  check(t.defs["lead"] ~= nil, "cache: second def recorded")
end

-- changedtick invalidation: edits rebuild.
do
  local b = mkbuf({ "no targets yet" })
  check(#radio.targets(b).phrases == 0, "cache: no defs initially")
  vim.api.nvim_buf_set_lines(b, 1, 1, false, { "now <<<added>>> here" })
  check(#radio.targets(b).phrases == 1, "cache: rebuilt after edit (changedtick)")
end

-- highlight: occurrences get an extmark; defs / code / links do not.
do
  local b = mkbuf({
    "Define <<<my phrase>>> here.",
    "Use my phrase plainly.",
    "In code ~my phrase~ stays.",
    "In a link [[x][my phrase]] stays.",
  })
  radio._apply(b)
  local NS = vim.api.nvim_create_namespace("organ_radio")
  local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })
  local rows = {}
  for _, m in ipairs(marks) do
    rows[m[2]] = true
  end
  check(rows[1] == true, "highlight: plain occurrence (row 1) marked")
  check(rows[0] ~= true, "highlight: definition (row 0) NOT marked")
  check(rows[2] ~= true, "highlight: occurrence inside ~code~ NOT marked")
  check(rows[3] ~= true, "highlight: occurrence inside a link NOT marked")
end

-- disabled: no marks.
do
  local b = mkbuf({ "Define <<<foo>>> then foo again." })
  require("organ.buf_config").set(b, "radio.enabled", false)
  radio._apply(b)
  local NS = vim.api.nvim_create_namespace("organ_radio")
  local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, {})
  check(#marks == 0, "highlight: radio.enabled=false places no marks")
end

-- follow: def_at returns the definition position for an occurrence.
do
  local b = mkbuf({
    "Define <<<my phrase>>> here.",
    "Jump from my phrase now.",
    "Plain text, no target.",
  })
  local pos = radio.def_at(b, 2, 12)
  check(pos ~= nil and pos.line == 1, "follow: def_at returns the definition line")
  check(radio.def_at(b, 3, 3) == nil, "follow: def_at nil off any occurrence")
  check(radio.def_at(b, 1, 12) == nil, "follow: def_at nil on the definition itself")
end

print("ALL PASS: radio_editor (cache)")
