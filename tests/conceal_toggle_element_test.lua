-- Per-element conceal toggle: a `false` config flag on `emphasis.bold`
-- (etc.) leaves bold markers visible while still concealing other
-- elements.  `:Org conceal toggle <element>` flips the flag at runtime
-- and re-applies marks to every loaded org buffer.
--
-- Run via: nvim --headless -l tests/conceal_toggle_element_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local conceal = require("organ.conceal")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "*bold* and /italic/ and =verbatim= and [[id:abc][a link]]",
})
vim.bo[b].filetype = "org"
vim.cmd("doautocmd FileType")

conceal._apply(b)
local NS = vim.api.nvim_get_namespaces().organ_emphasis_conceal

local function marks_for_byte(col)
  -- Return any conceal extmark covering byte column `col` on row 0.
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })) do
    local row, scol, opts = m[2], m[3], m[4]
    local ec = opts.end_col or scol + 1
    if row == 0 and scol <= col and col < ec then
      out[#out + 1] = m
    end
  end
  return out
end

-- Initial state: every element concealed (defaults are all true).
check("bold open `*` concealed", #marks_for_byte(0) > 0)
check("italic open `/` concealed", #marks_for_byte(11) > 0)
check("verbatim open `=` concealed", #marks_for_byte(24) > 0)

-- Toggle bold off; bold markers stay visible, others still concealed.
local new_bold = conceal.toggle_element("bold")
check("toggle_element returns new state", new_bold == false)
check("after toggle: bold open `*` NOT concealed", #marks_for_byte(0) == 0)
check("after toggle: italic still concealed", #marks_for_byte(11) > 0)
check("after toggle: verbatim still concealed", #marks_for_byte(24) > 0)

-- Toggle bold back on.
local back_on = conceal.toggle_element("bold")
check("re-toggle returns true", back_on == true)
check("after re-toggle: bold concealed again", #marks_for_byte(0) > 0)

-- Toggle links off independently.
conceal.toggle_element("links")
check("after links toggle: bold still concealed", #marks_for_byte(0) > 0)
-- Link `[[` starts at col 36 in our line.
check("after links toggle: link `[[` NOT concealed", #marks_for_byte(36) == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("conceal_toggle_element_test: PASS")
os.exit(0)
