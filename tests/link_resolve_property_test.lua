-- Unit tests for link.resolve — unknown schemes strip the prefix so the
-- target is just the value (for property-value link resolution).
-- Run via: nvim --headless -l tests/link_resolve_property_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local link = require("organ.link")

-- Each row: { input, expected_type, expected_target }
local cases = {
  -- Unknown schemes: scheme stripped.
  { "ROAM_REFS:https://a.com", "ROAM_REFS", "https://a.com" },
  { "ROAM_REFS:@knuth1984", "ROAM_REFS", "@knuth1984" },
  { "BIBKEY:abc", "BIBKEY", "abc" },
  { "cite:knuth1984", "cite", "knuth1984" },
  { "myprop:value", "myprop", "value" },
  -- Case-sensitive: KEY preserved verbatim.
  { "roam_refs:foo", "roam_refs", "foo" },
  -- Empty value still parses.
  { "ROAM_REFS:", "ROAM_REFS", "" },
  -- Reserved schemes UNCHANGED.
  { "id:abc-123", "id", "abc-123" },
  { "attachment:a.pdf", "attachment", "a.pdf" },
  -- URL schemes still keep the full URI in the target.
  { "http://example.com", "http", "http://example.com" },
  { "https://example.com", "https", "https://example.com" },
  { "mailto:foo@bar.com", "mailto", "mailto:foo@bar.com" },
}

for _, c in ipairs(cases) do
  local input, want_type, want_target = c[1], c[2], c[3]
  local got_type, got_target = link.resolve(input)
  if got_type ~= want_type or got_target ~= want_target then
    io.stderr:write(
      string.format(
        "resolve(%q) = (%q, %q), expected (%q, %q)\n",
        input,
        tostring(got_type),
        tostring(got_target),
        want_type,
        want_target
      )
    )
    os.exit(1)
  end
end

io.write("link resolve property ok\n")
os.exit(0)
