-- Unit tests for link.resolve — target-text → (target_type, stripped_target).
-- Run via: nvim --headless -l tests/link_resolve_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local link = require("organ.link")

local cases = {
  { "id:abc-123", "id", "abc-123" },
  { "file:/tmp/x.org", "file", "/tmp/x.org" },
  { "file:./rel.org", "file", "./rel.org" },
  { "http://example.com", "http", "http://example.com" },
  { "https://example.com", "https", "https://example.com" },
  { "mailto:foo@bar.com", "mailto", "mailto:foo@bar.com" },
  { "attachment:a.pdf", "attachment", "a.pdf" },
  { "*Some Heading", "headline", "Some Heading" },
  { "/abs/path.org", "file", "/abs/path.org" },
  { "./rel/path.org", "file", "./rel/path.org" },
  { "../rel.org", "file", "../rel.org" },
  { "random text", "text", "random text" },
  { "custom:thing", "custom", "thing" }, -- unknown scheme → strip
}

for _, c in ipairs(cases) do
  local ttype, tstrip = link.resolve(c[1])
  if ttype ~= c[2] or tstrip ~= c[3] then
    io.stderr:write(
      string.format(
        "resolve(%q) = (%q,%q), expected (%q,%q)\n",
        c[1],
        tostring(ttype),
        tostring(tstrip),
        c[2],
        c[3]
      )
    )
    os.exit(1)
  end
end

io.write("link resolve ok\n")
os.exit(0)
