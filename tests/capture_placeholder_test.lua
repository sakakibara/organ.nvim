-- Unit tests for capture.placeholder.expand — substitution pass.
-- (Prompt pass tested separately in capture_prompts_test.)
-- Run via: nvim --headless -l tests/capture_placeholder_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local placeholder = require("organ.capture.placeholder")

-- Helper: fixed-time ctx so tests are reproducible.
local function make_ctx(overrides)
  local ctx = {
    source_bufnr = 0,
    source_win = 0,
    source_cursor = { 1, 0 },
    source_file = "/abs/source.org",
    source_headline_id = nil,
    source_headline_title = nil,
    cword = "test",
    visual_text = "",
    prompts = { text = {}, tags = nil, dates = {} },
    now = os.time({ year = 2026, month = 4, day = 26, hour = 14, min = 30, sec = 0 }),
  }
  for k, v in pairs(overrides or {}) do
    ctx[k] = v
  end
  return ctx
end

-- 1. %? captured + cursor offset returned.
do
  local text, cur = placeholder.expand("hello %? world", make_ctx())
  assert(text == "hello  world", "text=" .. text)
  assert(cur == #"hello ", "cursor offset should be after 'hello '; got " .. tostring(cur))
end

-- 2. No %? → cursor offset is nil.
do
  local text, cur = placeholder.expand("just text", make_ctx())
  assert(text == "just text")
  assert(cur == nil)
end

-- 3. Multiple %? → first wins.
do
  local text, cur = placeholder.expand("a %? b %? c", make_ctx())
  assert(text == "a  b  c")
  assert(cur == #"a ")
end

-- 4. %% → literal %.
do
  local text = placeholder.expand("100%% sure", make_ctx())
  assert(text == "100% sure", "got: " .. text)
end

-- 5. %t / %T / %u / %U produce timestamps in the expected envelope.
do
  local text = placeholder.expand("%t %T %u %U", make_ctx())
  assert(text:match("<2026%-04%-26 [A-Z][a-z]+>"), "active date: " .. text)
  assert(text:match("<2026%-04%-26 [A-Z][a-z]+ %d%d:%d%d>"), "active datetime: " .. text)
  assert(text:match("%[2026%-04%-26 [A-Z][a-z]+%]"), "inactive date: " .. text)
  assert(text:match("%[2026%-04%-26 [A-Z][a-z]+ %d%d:%d%d%]"), "inactive datetime: " .. text)
end

-- 6. %i substitutes ctx.visual_text.
do
  local text = placeholder.expand("see %i below", make_ctx({ visual_text = "FOOBAR" }))
  assert(text == "see FOOBAR below")
end

-- 7. %a — id-bearing org headline → [[id:...][Title]].
do
  local text = placeholder.expand(
    "%a",
    make_ctx({
      source_file = "/x.org",
      source_headline_id = "abc-123",
      source_headline_title = "My Heading",
    })
  )
  assert(text == "[[id:abc-123][My Heading]]", "got: " .. text)
end

-- 8. %a — org headline without id → [[file:path::*Heading][Heading]].
do
  local text = placeholder.expand(
    "%a",
    make_ctx({
      source_file = "/x.org",
      source_headline_title = "My Heading",
    })
  )
  assert(text == "[[file:/x.org::*My Heading][My Heading]]", "got: " .. text)
end

-- 9. %a — non-org buffer with file → [[file:path][basename:line]].
do
  local text = placeholder.expand(
    "%a",
    make_ctx({
      source_file = "/path/to/file.txt",
      source_cursor = { 42, 0 },
    })
  )
  assert(text == "[[file:/path/to/file.txt][file.txt:42]]", "got: " .. text)
end

-- 10. %a — no source file → empty string.
do
  local text = placeholder.expand("%a", make_ctx({ source_file = "" }))
  assert(text == "", "got: '" .. text .. "'")
end

-- 11. %^{Prompt} substitutes from ctx.prompts.text by occurrence index.
do
  local text = placeholder.expand(
    "hi %^{Name}, age %^{Age}",
    make_ctx({
      prompts = { text = { "alice", "30" }, tags = nil, dates = {} },
    })
  )
  assert(text == "hi alice, age 30", "got: " .. text)
end

-- 12. %^{Prompt|opt|opt2} also pulls from ctx.prompts.text.
do
  local text = placeholder.expand(
    "color: %^{Color|red|blue}",
    make_ctx({
      prompts = { text = { "blue" }, tags = nil, dates = {} },
    })
  )
  assert(text == "color: blue", "got: " .. text)
end

-- 13. %^g pulls from ctx.prompts.tags.
do
  local text = placeholder.expand(
    "Tags: %^g",
    make_ctx({
      prompts = { text = {}, tags = ":work:urgent:", dates = {} },
    })
  )
  assert(text == "Tags: :work:urgent:")
end

-- 14. %^t / %^T pull from ctx.prompts.dates.
do
  local text = placeholder.expand(
    "when: %^t at %^T",
    make_ctx({
      prompts = { text = {}, tags = nil, dates = { "2026-05-01", "2026-05-01 09:00" } },
    })
  )
  assert(text == "when: 2026-05-01 at 2026-05-01 09:00", "got: " .. text)
end

-- 15. %<%H:%M> expands via os.date.
do
  local out = placeholder.expand(
    "* %<%H:%M> hello",
    make_ctx({
      now = os.time({ year = 2026, month = 4, day = 27, hour = 14, min = 23, sec = 0 }),
    })
  )
  assert(out:find("14:23"), "expected 14:23 in output, got: " .. out)
end

-- 16. Unclosed %< leaves % verbatim.
do
  local out = placeholder.expand("%<not-closed", make_ctx())
  assert(out:find("%%"), "unclosed %< should leave % verbatim, got: " .. out)
end

io.write("capture placeholder ok\n")
os.exit(0)
