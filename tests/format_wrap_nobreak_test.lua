-- Wrapping never starts a new element on the line it creates: a break
-- that would put a headline, bullet, ordered counter, keyword, table
-- row or footnote label at column 0 is refused, and timestamps are
-- never split.  Break points are checked against GNU Emacs 30.2 /
-- Org 9.7.11 (`fill-nobreak-p` plus org's `fill-nobreak-predicate`).
--
-- Run via: nvim --headless -l tests/format_wrap_nobreak_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

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

-- An unattended pass leaves prose alone by default; every case here is
-- about the wrap pass itself, so turn it on for the buffer under test.
local function format_buf(textwidth, input)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = textwidth
  require("organ.buf_config").set(b, "format.wrap.enabled", true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, input)
  fmt.format_buffer(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return out
end

local function wrap_only(width, input)
  return fmt.format_lines(input, {
    wrap = { width = width },
    headline = { normalize_whitespace = false },
    blanks = {},
  }, nil)
end

-- (a) A `*` word must not be pushed to column 0: that is a headline.
do
  local out = format_buf(80, {
    "* Shell notes",
    "In shell globbing the character that matches any sequence of characters is just * and it is called the star.",
  })
  local invented = false
  for i = 2, #out do
    if out[i]:match("^%*+%s") then
      invented = true
    end
  end
  check("wrap does not invent a headline", not invented, vim.inspect(out))
end

-- (b) A `42.` word must not be pushed to column 0: that is an ordered
-- list item, and the list pass then renumbers it to `1.`.
do
  local out = format_buf(80, {
    "* N",
    "Consult the appendix and then the index and then the glossary on page 42. It has everything you want.",
  })
  local invented = false
  for i = 2, #out do
    if out[i]:match("^%s*%d+[.)]%s") or out[i]:match("^%s*[-+*]%s") then
      invented = true
    end
  end
  check("wrap does not invent a list item", not invented, vim.inspect(out))
  check(
    "author's number survives",
    table.concat(out, " "):find("page 42.", 1, true) ~= nil,
    vim.inspect(out)
  )
end

-- (c) Timestamps never span a line break.
do
  for _, case in ipairs({
    { 60, "Some words here to push things along word <2026-01-01 Thu 10:00> tail" },
    { 60, "Some words here to push things along wor [2026-01-01 Thu 10:00] tail" },
    { 60, "Some words here to push things al word <2026-01-01 Thu>--<2026-01-05 Mon> tail" },
  }) do
    local out = wrap_only(case[1], { case[2] })
    local split = false
    for _, l in ipairs(out) do
      local opens = select(2, l:gsub("<%d%d%d%d%-", ""))
      local closes = select(2, l:gsub(">", ""))
      if opens ~= closes then
        split = true
      end
      if l:match("^%d%d:%d%d>") or l:match("^%a%a%a[%]>]") then
        split = true
      end
    end
    check("timestamp not split at width " .. case[1], not split, vim.inspect(out))
  end
end

-- (d) Break points match Emacs.  A 16-word, 79-column prefix followed by
-- one token, filled at 80: Emacs keeps all 16 prefix words when the
-- token may start a line and backs up to 15 when it may not.  The
-- expectations below were read off `emacs --batch -Q -l org`.
do
  local prefix = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo pppp"
  local expected = {
    ["Z"] = 16,
    ["42x"] = 16,
    [">"] = 16,
    ["*bold*"] = 16,
    [":tag:"] = 16,
    ["-----"] = 16,
    ["+---+"] = 16,
    ["-x"] = 16,
    ["+x"] = 16,
    ["*x"] = 16,
    [":x"] = 16,
    ["#x"] = 16,
    ["42.x"] = 16,
    ["1)x"] = 16,
    ["#+"] = 16,
    ["%%"] = 16,
    ["*"] = 15,
    ["**"] = 15,
    ["***"] = 15,
    ["-"] = 15,
    ["+"] = 15,
    ["|"] = 15,
    [":"] = 15,
    ["#"] = 15,
    ["42."] = 15,
    ["1)"] = 15,
    ["5."] = 15,
    ["|foo"] = 15,
    ["#+TITLE:"] = 15,
    ["[fn:1]"] = 15,
    ["%%(diary)"] = 15,
    ["\\begin{eq}"] = 15,
  }
  for token, want in pairs(expected) do
    local out = wrap_only(80, { prefix .. " " .. token .. " zzzz yyyy xxxx wwww vvvv" })
    local got = 0
    for _ in (out[1] or ""):gmatch("%S+") do
      got = got + 1
    end
    check(
      ("break before %q keeps %d words"):format(token, want),
      got == want,
      ("got %d: %q"):format(got, out[1])
    )
  end
end

-- (e) When no earlier break is acceptable the line is left long rather
-- than broken into a new element.
do
  local out = wrap_only(22, { "supercalifragilistic * tail" })
  check(
    "no acceptable break: line left long",
    vim.deep_equal(out, { "supercalifragilistic *", "tail" }),
    vim.inspect(out)
  )
  local out2 = wrap_only(4, { "aa * bb cc dd" })
  check(
    "degenerate width: never a bare bullet line",
    vim.deep_equal(out2, { "aa *", "bb", "cc", "dd" }),
    vim.inspect(out2)
  )
end

-- (f) Org ends a list item at a line indented no further than the
-- bullet; such a line is a separate paragraph, not item content.
do
  local out = format_buf(80, {
    "- item one",
    "This paragraph is at column zero and should not be part of the item.",
  })
  check(
    "column-0 line after a bullet stays a paragraph",
    vim.deep_equal(
      out,
      { "- item one", "This paragraph is at column zero and should not be part of the item." }
    ),
    vim.inspect(out)
  )
  local out2 = wrap_only(80, { "  - item one", "  cont at the bullet column" })
  check(
    "line at the bullet column ends the item",
    vim.deep_equal(out2, { "  - item one", "  cont at the bullet column" }),
    vim.inspect(out2)
  )
  local out3 = wrap_only(80, { "- item one", " indented one column" })
  check("line past the bullet column continues the item", #out3 == 1, vim.inspect(out3))
end

-- (g) `textwidth = 0` is Vim for "do not hard-wrap".
do
  local long =
    "this is a fairly long line of prose that goes past eighty columns for sure yes it does indeed go past"
  local out = format_buf(0, { "* H", long })
  check("textwidth=0 does not hard-wrap", vim.deep_equal(out, { "* H", long }), vim.inspect(out))
  local out2 = format_buf(40, { "* H", long })
  check("textwidth=40 still wraps", #out2 > 2, vim.inspect(out2))
end

-- (h) The two spaces Emacs writes after a sentence end survive a
-- reformat, so an Emacs-authored file is not rewritten on save.
do
  local out = wrap_only(200, { "One sentence ends here.  Another begins here." })
  check(
    "double sentence space preserved",
    out[1] == "One sentence ends here.  Another begins here.",
    vim.inspect(out)
  )
  local out2 = wrap_only(200, { "One  two   three four" })
  check("other runs collapse to one space", out2[1] == "One two three four", vim.inspect(out2))
end

-- (i) A `:NAME:` line with no matching `:END:` is not a drawer, so it
-- must not suppress wrapping for the rest of the buffer.
do
  local out = wrap_only(40, {
    "* H",
    ":Note:",
    "this is a long prose line that ought to be wrapped at forty columns but is not",
  })
  check("stray :NAME: kept on its own line", out[2] == ":Note:", vim.inspect(out))
  check("prose after a stray :NAME: still wraps", #out > 3, vim.inspect(out))
  local drawer = wrap_only(40, {
    "* H",
    ":PROPERTIES:",
    ":ID:       a long value that must not be rewrapped by the formatter",
    ":END:",
    "this is a long prose line that ought to be wrapped at forty columns",
  })
  check(
    "real drawer body still passes through",
    drawer[3]:match("^:ID:") ~= nil,
    vim.inspect(drawer)
  )
  check("prose after a real drawer wraps", #drawer > 5, vim.inspect(drawer))

  -- A range stopping before the drawer's `:END:` must still see it.
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 40
  local input = {
    "* H",
    ":PROPERTIES:",
    ":ID:       0f2a9c2e-1111-2222-3333-444455556666",
    ":END:",
    "body",
  }
  vim.api.nvim_buf_set_lines(b, 0, -1, false, input)
  fmt.format_range(b, 2, 3)
  local ranged = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  check(
    "range ending inside a drawer leaves it alone",
    vim.deep_equal(ranged, input),
    vim.inspect(ranged)
  )
end

-- (j) A whitespace-free CJK run wraps between characters.
do
  local out =
    wrap_only(20, { "あいうえおかきくけこさしすせそたちつてとなにぬねの" })
  check("CJK run is wrapped", #out == 3, vim.inspect(out))
  for _, l in ipairs(out) do
    check("CJK line within width", vim.fn.strdisplaywidth(l) <= 20, l)
  end
  local mixed = wrap_only(20, {
    "hello world あいうえおかきくけこさしすせそたちつてとなにぬねの done",
  })
  check(
    "CJK packs onto the preceding line",
    mixed[1] == "hello world あいうえ",
    vim.inspect(mixed)
  )
end

-- (k) Fuzz: paragraphs built from ordinary words plus org-significant
-- tokens never gain an element start, never split a timestamp, and
-- formatting twice equals formatting once.
do
  local started = os.clock()
  local words = {
    "alpha",
    "be",
    "cat",
    "delta",
    "echo",
    "fox",
    "golf",
    "hotel",
    "iris",
    "jam",
    "kilo",
    "word.",
  }
  local tokens = {
    "*",
    "**",
    "-",
    "+",
    "|",
    ":",
    "#",
    "42.",
    "1)",
    "#+TITLE:",
    "#+BEGIN_SRC",
    "[fn:1]",
    "%%(diary)",
    "\\begin{eq}",
    "|foo",
    "*bold*",
    ":tag:",
    "-----",
    "+---+",
    "<2026-01-01 Thu 10:00>",
    "[2026-02-03 Tue]",
    "<2026-01-01 Thu>--<2026-01-05 Mon>",
    "あいうえおかきくけこ",
    "テスト、テスト。",
  }
  local seed = 20260903
  local function rnd(n)
    seed = (1103515245 * seed + 12345) % 2147483648
    return (math.floor(seed / 65536) % n) + 1
  end

  local function element_start(line)
    return line:match("^%*+%s") ~= nil
      or line:match("^%s*[-+*]%s") ~= nil
      or line:match("^%s*%d+[.)]%s") ~= nil
      or line:match("^%s*|") ~= nil
      or line:match("^%s*:%s") ~= nil
      or line:match("^%s*#%s") ~= nil
      or line:match("^%s*#%+") ~= nil
      or line:match("^%s*%[fn:") ~= nil
      or line:match("^%s*%%%%%(") ~= nil
      or line:match("^%s*\\begin{") ~= nil
  end

  local bad_element, bad_timestamp, bad_fixpoint = nil, nil, nil
  for _ = 1, 250 do
    local parts = { words[rnd(#words)] }
    for _ = 2, rnd(26) + 4 do
      if rnd(5) == 1 then
        parts[#parts + 1] = tokens[rnd(#tokens)]
      else
        parts[#parts + 1] = words[rnd(#words)]
      end
    end
    local input = { table.concat(parts, " ") }
    local width = ({ 20, 40, 72 })[rnd(3)]
    local once = wrap_only(width, input)
    local twice = wrap_only(width, once)
    for _, l in ipairs(once) do
      if element_start(l) and not bad_element then
        bad_element = table.concat(input, " ") .. " -> " .. vim.inspect(once)
      end
    end
    local want_ts = select(2, input[1]:gsub("[<%[]%d%d%d%d%-%d%d%-%d%d[^<>%[%]]*[>%]]", ""))
    local got_ts = 0
    for _, l in ipairs(once) do
      got_ts = got_ts + select(2, l:gsub("[<%[]%d%d%d%d%-%d%d%-%d%d[^<>%[%]]*[>%]]", ""))
    end
    if want_ts ~= got_ts and not bad_timestamp then
      bad_timestamp = table.concat(input, " ") .. " -> " .. vim.inspect(once)
    end
    if not vim.deep_equal(once, twice) and not bad_fixpoint then
      bad_fixpoint = vim.inspect(once) .. " -> " .. vim.inspect(twice)
    end
  end
  check("fuzz: no invented element start", bad_element == nil, bad_element)
  check("fuzz: no split timestamp", bad_timestamp == nil, bad_timestamp)
  check("fuzz: formatting is a fixpoint", bad_fixpoint == nil, bad_fixpoint)
  local elapsed = os.clock() - started
  check("fuzz: bounded runtime", elapsed < 20, ("took %.1fs"):format(elapsed))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_wrap_nobreak_test: PASS")
