-- Org formatter (paragraph rewrap) preserves structure: headlines
-- never wrap, drawers/blocks/planning lines pass through verbatim,
-- list items rewrap continuation under the bullet's indent column.
--
-- Run via: nvim --headless -l tests/format_test.lua

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

local fmt = require("organ.format")

-- (a) Headlines never wrap, even when longer than textwidth.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 40
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO This is a very long headline that exceeds forty characters easily",
    "Body text here.",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "headline > textwidth: NOT wrapped",
    lines[1] == "* TODO This is a very long headline that exceeds forty characters easily",
    vim.inspect(lines)
  )
end

-- (b) With wrap turned on, a plain prose paragraph rewraps to textwidth.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 30
  require("organ.buf_config").set(b, "format.wrap.enabled", true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Heading",
    "this is a single long line that should rewrap to thirty chars per line",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- Heading stays.  Subsequent lines: each ≤ 30 chars.
  check("prose: heading preserved", lines[1] == "* Heading")
  for i = 2, #lines do
    check(
      ("prose line %d ≤ 30 chars"):format(i),
      #lines[i] <= 30,
      ("got %d: %q"):format(#lines[i], lines[i])
    )
  end
end

-- (c) Drawer contents pass through verbatim.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 20
  local input = {
    "* H",
    ":PROPERTIES:",
    ":ID: this-is-a-very-long-id-that-should-not-wrap",
    ":END:",
    "Body.",
  }
  vim.api.nvim_buf_set_lines(b, 0, -1, false, input)
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "drawer content: long ID not wrapped (org-property-format aligned)",
    lines[3] == ":ID:       this-is-a-very-long-id-that-should-not-wrap",
    vim.inspect(lines)
  )
end

-- (d) Source block contents pass through verbatim (would be invalid
-- code if wrapped).
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 20
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "#+begin_src python",
    "def long_function_name_here(arg1, arg2): return arg1 + arg2",
    "#+end_src",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "src block: long code line preserved",
    lines[2] == "def long_function_name_here(arg1, arg2): return arg1 + arg2",
    vim.inspect(lines)
  )
end

-- (e) List item rewraps continuation under bullet indent.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 30
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* H",
    "- this is a long list item that should wrap under the bullet column",
  })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- First line of list item starts with `- `; subsequent lines
  -- start with two spaces (bullet width).
  check("list item: starts with `- `", lines[2]:sub(1, 2) == "- ", vim.inspect(lines))
  if lines[3] then
    check(
      "list continuation: starts with two-space indent",
      lines[3]:sub(1, 2) == "  ",
      vim.inspect(lines)
    )
  end
end

-- (f) format_range exercises the same code path as formatexpr but
-- without the v:lnum/v:count ceremony (those are read-only outside
-- a real `gq` invocation).  `gq` fills whatever `format.wrap.enabled`
-- says, so it passes `force_wrap`; a ranged `:Org format` does not.
do
  local function ranged(opts)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].textwidth = 25
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {
      "* H",
      "long line one that should wrap to twenty five chars across multiple",
    })
    fmt.format_range(b, 2, 2, opts)
    local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    vim.api.nvim_buf_delete(b, { force = true })
    return out
  end
  local lines = ranged({ force_wrap = true })
  check("gq path: rewrapped line 2", #lines >= 2 and #lines[2] <= 25, vim.inspect(lines))
  local plain = ranged(nil)
  check(
    "ranged :Org format leaves prose as written",
    #plain == 2 and #plain[2] > 25,
    vim.inspect(plain)
  )
end

-- Emacs-parity: `\\` at end of line is org's hard line-break syntax.
-- Verified against GNU Emacs 30.2 `org-mode` + `fill-paragraph`.  Lines
-- ending in `\\` (optional trailing whitespace) MUST stay split; other
-- consecutive non-blank lines reflow into one paragraph.  Trailing
-- spaces alone (markdown convention) have no meaning in org.
local function format_input(input, cfg)
  return fmt.format_lines(input, cfg or { wrap = { width = 80 } })
end

do
  local got = format_input({ "first line", "second line" })
  check(
    "Emacs parity A: plain lines reflow into one paragraph",
    #got == 1 and got[1] == "first line second line",
    vim.inspect(got)
  )
end

do
  local got = format_input({ "first line \\\\", "second line" })
  check(
    "Emacs parity B: `\\\\` at EOL preserved as hard break",
    #got == 2 and got[1] == "first line \\\\" and got[2] == "second line",
    vim.inspect(got)
  )
end

do
  local got = format_input({ "first \\\\", "second", "third" })
  check(
    "Emacs parity C: lines after `\\\\` still reflow among themselves",
    #got == 2 and got[1] == "first \\\\" and got[2] == "second third",
    vim.inspect(got)
  )
end

do
  local got = format_input({ "first line  ", "second line" })
  check(
    "Emacs parity D: trailing spaces (markdown convention) ignored",
    #got == 1 and got[1] == "first line second line",
    vim.inspect(got)
  )
end

do
  local got = format_input(
    { "one two three four five six seven eight nine ten eleven twelve" },
    { wrap = { width = 30 } }
  )
  check("Emacs parity E: wraps wider lines at width", #got >= 2, vim.inspect(got))
end

-- Headline normalizer field order: todo -> priority -> COMMENT, matching
-- the indexer's parse_heading_line (org-element order).
do
  local got = format_input({ "* TODO [#A] COMMENT Title" })
  check(
    "canonical order '* TODO [#A] COMMENT Title' round-trips unchanged",
    got[1] == "* TODO [#A] COMMENT Title",
    vim.inspect(got)
  )
end

do
  -- With normalize_whitespace off, only RECOGNIZED fields get collapsed to
  -- a single join space; unrecognized text is passed through verbatim.
  -- Reversed order (COMMENT before the cookie) must NOT recognize "[#A]"
  -- as a priority cookie -- it is only valid immediately after TODO -- so
  -- it stays part of the raw title, whitespace and all.
  local cfg = { headline = { normalize_whitespace = false, tags_column = 40 } }
  local got = fmt.format_lines({ "* TODO COMMENT [#A]  Title" }, cfg)
  check(
    "reversed 'COMMENT [#A]' keeps '[#A]  Title' as untouched title text",
    got[1] == "* TODO COMMENT [#A]  Title",
    vim.inspect(got)
  )
end

do
  -- No-space discriminator: the priority-cookie scan runs once, right
  -- after TODO. Since "[#A]" here follows COMMENT (not TODO), it is
  -- never seen as a cookie -- it stays raw title text glued to "Title"
  -- with zero whitespace between them, so normalize_whitespace has
  -- nothing to collapse. The old parse order (cookie scanned after
  -- COMMENT was stripped) would have matched "[#A]" as a phantom cookie
  -- here and reassembled with an inserted join space.
  local got = format_input({ "* TODO COMMENT [#A]Title" })
  check(
    "no-space 'COMMENT [#A]Title' passes through verbatim under default config",
    got[1] == "* TODO COMMENT [#A]Title",
    vim.inspect(got)
  )
end

-- Emacs `org-fill-paragraph` never touches fixed-width lines, and a
-- horizontal rule is its own element: neither joins the surrounding
-- prose.
do
  local got = format_input({ "* H", ": fixed one", ": fixed two", ":", "para" })
  check(
    "fixed-width lines pass through unwrapped",
    vim.deep_equal(got, { "* H", ": fixed one", ": fixed two", ":", "para" }),
    vim.inspect(got)
  )
end

do
  local got = format_input({ "para a", "-----", "para b", "para c" })
  check(
    "horizontal rule separates paragraphs",
    vim.deep_equal(got, { "para a", "-----", "para b para c" }),
    vim.inspect(got)
  )
end

-- Comments fill with the `# ` prefix on every line; a bare `#` line
-- splits comment paragraphs; prose never merges into a comment.
do
  local got = format_input({ "  # comment one", "  # comment two", "para" })
  check(
    "comment lines fill under the comment prefix",
    vim.deep_equal(got, { "  # comment one comment two", "para" }),
    vim.inspect(got)
  )
end

do
  local got = format_input({ "#", "# a", "# b", "#", "# c" })
  check(
    "bare `#` separates comment paragraphs",
    vim.deep_equal(got, { "#", "# a b", "#", "# c" }),
    vim.inspect(got)
  )
end

do
  local got = format_input({ "para", "# a", "# b" })
  check(
    "comment after prose stays separate",
    vim.deep_equal(got, { "para", "# a b" }),
    vim.inspect(got)
  )
end

do
  local long = "# " .. string.rep("word ", 20)
  local got = format_input({ long }, { wrap = { width = 30 } })
  local ok = #got > 1
  for _, l in ipairs(got) do
    if not l:match("^# %S") or vim.fn.strdisplaywidth(l) > 30 then
      ok = false
    end
  end
  check("long comment wraps with the prefix on each line", ok, vim.inspect(got))
end

-- Width is measured in display columns, not bytes.
do
  local cjk = string.rep("\227\129\130", 30) -- 30 x U+3042, 60 columns, 90 bytes
  local got = format_input({ cjk .. " " .. cjk }, { wrap = { width = 130 } })
  check("CJK text within the column width is not wrapped", #got == 1, vim.inspect(got))
  got = format_input({ cjk .. " " .. cjk }, { wrap = { width = 100 } })
  check("CJK text wider than the column width wraps", #got == 2, vim.inspect(got))
end

-- A bare bullet is an item (Emacs `org-at-item-p`), not prose to join.
do
  local got = format_input({ "- a", "-", "- b" })
  check(
    "bare bullet stays its own item",
    vim.deep_equal(got, { "- a", "-", "- b" }),
    vim.inspect(got)
  )
end

-- format_buffer leaves the last line non-empty so the written file ends
-- with exactly one newline.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", "body" })
  fmt.format_buffer(b)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "format_buffer adds no trailing empty line",
    vim.deep_equal(lines, { "* A", "body" }),
    vim.inspect(lines)
  )
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* A", "body", "", "" })
  fmt.format_buffer(b)
  lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "format_buffer strips trailing empty lines",
    vim.deep_equal(lines, { "* A", "body" }),
    vim.inspect(lines)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_test: PASS")
