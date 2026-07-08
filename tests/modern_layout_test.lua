-- layout.lua composes right-column segments (priority/cookies/tags) into a
-- single right_align extmark per row, in ascending slot order, space-joined.
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local render = require("organ.modern.render")
local layout = require("organ.modern.layout")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* headline" })
local ns = render.ns

-- Add out of order: tags (slot 3) before priority (slot 1); flush must sort.
layout.add(b, 0, layout.SLOT.tags, { { "work", "@organ.modern.tag" } })
layout.add(b, 0, layout.SLOT.priority, { { "A", "@organ.modern.priority.a" } })
layout.flush(b, ns)

local marks = vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
local ra
for _, m in ipairs(marks) do
  if m[4].virt_text_pos == "right_align" then
    ra = m[4]
  end
end
check(
  "exactly one right_align extmark on the row",
  #marks == 1 and ra ~= nil,
  "marks=" .. vim.inspect(marks)
)
check(
  "priority (slot 1) chunk precedes tags (slot 3) chunk",
  ra and ra.virt_text[1][1] == "A" and ra.virt_text[3][1] == "work",
  ra and vim.inspect(ra.virt_text) or "no right_align mark"
)
check(
  "a single space separates the two segments",
  ra and ra.virt_text[2][1] == " ",
  ra and vim.inspect(ra.virt_text) or "nil"
)

-- flush() must clear the accumulator: a second flush with nothing added emits nothing.
vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
layout.flush(b, ns)
check(
  "flush clears the accumulator (no marks on empty flush)",
  #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) == 0
)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
print("\nmodern_layout_test: PASS")
os.exit(0)
