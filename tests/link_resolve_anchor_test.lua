-- Unit tests for link.resolve — anchor as 3rd return for file: links.
-- Run via: nvim --headless -l tests/link_resolve_anchor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local link = require("organ.link")

-- Each row: { input, expected_type, expected_target, expected_anchor }
local cases = {
  { "file:x.org::*Heading", "file", "x.org", "*Heading" },
  { "file:x.org::#cust-id", "file", "x.org", "#cust-id" },
  { "file:x.org::42", "file", "x.org", "42" },
  { "file:x.org::any text here", "file", "x.org", "any text here" },
  { "file:x.org", "file", "x.org", nil },
  { "file:dir::sub::*H", "file", "dir", "sub::*H" },
  -- non-file types: anchor must be nil (signature still works)
  { "id:abc-123", "id", "abc-123", nil },
  { "*Some Heading", "headline", "Some Heading", nil },
}

for _, c in ipairs(cases) do
  local input, want_type, want_target, want_anchor = c[1], c[2], c[3], c[4]
  local got_type, got_target, got_anchor = link.resolve(input)
  if got_type ~= want_type or got_target ~= want_target or got_anchor ~= want_anchor then
    io.stderr:write(
      string.format(
        "resolve(%q) = (%q, %q, %s), expected (%q, %q, %s)\n",
        input,
        tostring(got_type),
        tostring(got_target),
        tostring(got_anchor),
        want_type,
        want_target,
        tostring(want_anchor)
      )
    )
    os.exit(1)
  end
end

io.write("link resolve anchor ok\n")
os.exit(0)
