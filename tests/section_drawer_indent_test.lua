-- canonicalize / format indents property + logbook drawers to the section
-- indent (level+1), like planning. Run via:
-- nvim --headless -l tests/section_drawer_indent_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

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

do
  local b = mkbuf({
    "* TODO Task",
    "DEADLINE: <2026-06-17 Wed>",
    ":PROPERTIES:",
    ":ID: abc",
    ":END:",
    ":LOGBOOK:",
    "CLOCK: [2026-06-16 Tue 09:00]",
    ":END:",
    "body text",
  })
  require("organ.format").format_buffer(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(out[2] == "  DEADLINE: <2026-06-17 Wed>", "planning indented (level+1)")
  check(out[3] == "  :PROPERTIES:", "property drawer open indented")
  check(out[4] == "  :ID:       abc", "property line indented + org-property-format aligned")
  check(out[5] == "  :END:", "property drawer close indented")
  check(out[6] == "  :LOGBOOK:", "logbook drawer open indented")
  check(out[7] == "  CLOCK: [2026-06-16 Tue 09:00]", "logbook line indented")
  check(out[9] == "body text", "body NOT indented (headline-data, adapt off)")
end

print("ALL PASS: section_drawer_indent")
