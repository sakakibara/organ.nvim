-- Deterministic org-document generator for the Emacs parity sweep.
--
--   local corpus = dofile(root .. "/tests/_parity_corpus.lua")
--   for _, text in ipairs(corpus.documents(20260904, 200)) do ... end
--
-- The hand-written fixtures under tests/fixtures/emacs_interop/parity/
-- cover the shapes someone thought to write down; this covers the
-- combinations nobody did.  A fixed seed keeps a failure reproducible:
-- the same seed and count always produce byte-identical documents.
--
-- The vocabulary deliberately ranges over the constructs an org parser
-- gets wrong -- non-ASCII titles and tags, punctuation-bearing property
-- keys, timestamp ranges, repeaters and warning periods, blocks whose
-- bodies contain lines that look like headlines, inline tasks, tables,
-- lists and footnotes.

local M = {}

local bit = require("bit")

-- xorshift32.  Lua numbers are doubles, so a multiply-based LCG would
-- lose the low bits it depends on past 2^53.
local Rng = {}
Rng.__index = Rng

local function new_rng(seed)
  local state = bit.band(seed, 0xffffffff)
  if state == 0 then
    state = 0x2545f491
  end
  return setmetatable({ state = state }, Rng)
end

function Rng:next()
  local x = self.state
  x = bit.bxor(x, bit.lshift(x, 13))
  x = bit.bxor(x, bit.rshift(x, 17))
  x = bit.bxor(x, bit.lshift(x, 5))
  self.state = x
  return bit.band(x, 0x7fffffff)
end

function Rng:float()
  return self:next() / 0x80000000
end

function Rng:int(lo, hi)
  return lo + self:next() % (hi - lo + 1)
end

function Rng:pick(list)
  return list[self:int(1, #list)]
end

function Rng:chance(p)
  return self:float() < p
end

local TODO_KEYWORDS = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "DONE", "CANCELLED" }
local PRIORITIES = { "A", "B", "C", "0", "1", "9" }

local TITLES = {
  "Write the report",
  "Fix bug in parser",
  "会議の準備をする",
  "日本語のタイトル",
  "Reunion generale",
  "Проверить отчёт",
  "مراجعة التقرير",
  "עברית כותרת",
  "Ship it 🚀 now",
  "cafe",
  "a b  c",
  "Tabs\there",
  "Link to [[https://example.com][site]]",
  "Emphasis *bold* and /italic/",
  "Colon: in title",
  "Bracket [x] here",
  "Percent 100% done",
  "Trailing star *",
  "Star * middle",
  "COMMENTARY not comment",
  "TODOish",
  "1. numbered-looking",
  "- dashy",
}

local TAGS = {
  "work",
  "home",
  "urgent",
  "_priv",
  "@office",
  "a1",
  "日本語",
  "проект",
  "ARCHIVE",
  "noexport",
  "с",
  "n%p",
  "x#y",
  "ＴＡＧ",
  "é",
}

local DATES = { "2026-01-02 Fri", "2026-05-04 Mon", "2025-12-31 Wed", "2026-02-28 Sat" }
local TIMES = { "", " 10:00", " 09:30-11:45", " 23:59" }
local REPEATERS = { "", " +1w", " ++1m", " .+2d", " +3y" }
local WARNINGS = { "", " -3d", " --1w", " -0d" }

local PROPERTY_KEYS = {
  "ID",
  "CUSTOM_ID",
  "CATEGORY",
  "EFFORT",
  "Effort",
  "ORDERED",
  "ROAM_ALIASES",
  "ROAM_REFS",
  "ARCHIVE",
  "COOKIE_DATA",
  "LOGGING",
  "my_prop",
  "MY-PROP",
  "A_B_C",
  "X+",
  "A.B",
  "日本語プロパティ",
  "header-args:python",
  "attr_html",
}

local PROPERTY_VALUES = {
  "1",
  "abc",
  "",
  "a: b",
  "  spaced  ",
  "value with :colons:",
  '"quoted"',
  "2:30",
  "日本語",
  "🎉",
  "multi word value",
  ":session s",
}

local LIST_BODIES = {
  { "- plain item", "- another", "  - nested" },
  { "1. first", "2. second", "3) third" },
  { "- [ ] unchecked", "- [X] checked", "- [-] partial" },
  { "- term :: definition", "- other :: more" },
  { "1. [@5] counter item", "2. next" },
  { "  + indented plus", "  + second" },
  { "- item with", "  continuation line", "", "- after blank" },
}

local TABLES = {
  { "| a | b |", "|---+---|", "| 1 | 2 |" },
  { "| <l> | <r> |", "| x | y |" },
  { "| a | b |", "|---|---|", "| 1 | 2 |", "#+TBLFM: $2=$1*2" },
  { "|  日本 | b |", "|-------+---|", "| 1 | 2 |" },
}

local BLOCKS = {
  { "#+begin_src python", "print('* not a headline')", "#+end_src" },
  { "#+BEGIN_EXAMPLE", "* looks like headline", "#+END_EXAMPLE" },
  { "#+begin_quote", "quoted text", "#+end_quote" },
  { "#+begin_verse", "line one", "  line two", "#+end_verse" },
  { "#+begin_export html", "<b>x</b>", "#+end_export" },
  { "#+begin_center", "centered", "#+end_center" },
  { "#+BEGIN_COMMENT", "* commented headline", "#+END_COMMENT" },
  { "#+begin_src emacs-lisp :results none", "(+ 1 2)", "#+end_src" },
}

local MISC = {
  { "# a comment line" },
  { "#+TITLE: Document title" },
  { "#+FILETAGS: :ft1:ft2:" },
  { ": fixed width line", ": another" },
  { "-----" },
  { "[fn:1] footnote definition text" },
  { "Text with [fn:2] a ref and [fn::inline def]." },
  { "A link [[file:foo.org::*Heading][desc]] and [[https://a.b/c%5D][x]]." },
  { "Cite [cite:@key1;@key2] and [cite/t:@k]." },
  { "{{{macro(arg1,arg2)}}} and {{{title}}}." },
  { "Entities: \\alpha \\copy \\nbsp{} \\Rightarrow." },
  { "Plain https://example.com/a_b and <https://x.y>." },
  { "<<target>> and <<<radio>>> here." },
  { "*** not a headline because indented" },
  { "  * indented star line" },
  { "Sub_script and super^{script} here." },
  { "\\begin{equation}", "x = y", "\\end{equation}" },
  { "#+CAPTION: cap", "#+NAME: nm", "| a |" },
}

local INLINE_TASKS = {
  { "*************** TODO inline task", "*************** END" },
}

local PARAGRAPHS = {
  "Some paragraph text here.",
  "  indented paragraph",
  "日本語の段落です。",
  "مرحبا بالعالم",
  "",
}

local PREAMBLES = {
  {},
  { "#+TITLE: Test", "#+AUTHOR: A", "" },
  { "#+TODO: TODO NEXT | DONE", "" },
  { "#+FILETAGS: :global:", "" },
  { "#+STARTUP: overview", "", "Intro paragraph.", "" },
  { ":PROPERTIES:", ":ID: file-level-id", ":END:", "#+title: roam node", "" },
}

local LOGBOOK_ENTRIES = {
  "CLOCK: [2026-01-02 Fri 10:00]--[2026-01-02 Fri 11:30] =>  1:30",
  '- State "DONE"       from "TODO"       [2026-01-02 Fri 12:00]',
}

local function append(target, items)
  for _, item in ipairs(items) do
    target[#target + 1] = item
  end
end

local function timestamp(rng, active, allow_range)
  local open, close = "<", ">"
  if not active then
    open, close = "[", "]"
  end
  local stamp = open
    .. rng:pick(DATES)
    .. rng:pick(TIMES)
    .. rng:pick(REPEATERS)
    .. rng:pick(WARNINGS)
    .. close
  if allow_range and rng:chance(0.15) then
    stamp = stamp .. "--" .. open .. rng:pick(DATES) .. rng:pick(TIMES) .. close
  end
  return stamp
end

local function headline(rng, level)
  local line = string.rep("*", level) .. " "
  if rng:chance(0.55) then
    line = line .. rng:pick(TODO_KEYWORDS) .. " "
  end
  if rng:chance(0.3) then
    line = line .. "[#" .. rng:pick(PRIORITIES) .. "] "
  end
  if rng:chance(0.06) then
    line = line .. "COMMENT "
  end
  line = line .. rng:pick(TITLES)
  if rng:chance(0.15) then
    line = line .. " " .. rng:pick({ "[1/3]", "[50%]", "[0/0]", "[100%]" })
  end
  if rng:chance(0.45) then
    local tags = {}
    for _ = 1, rng:int(1, 3) do
      tags[#tags + 1] = rng:pick(TAGS)
    end
    line = line .. " :" .. table.concat(tags, ":") .. ":"
  end
  return line
end

-- One planning line only: Emacs reads the line directly under the
-- headline as planning and everything after it as body text.
local function planning(rng)
  local entries = {}
  if rng:chance(0.6) then
    entries[#entries + 1] = "SCHEDULED: " .. timestamp(rng, true, true)
  end
  if rng:chance(0.5) then
    entries[#entries + 1] = "DEADLINE: " .. timestamp(rng, true, true)
  end
  if rng:chance(0.3) then
    entries[#entries + 1] = "CLOSED: " .. timestamp(rng, false, false)
  end
  if #entries == 0 then
    return {}
  end
  return { rng:pick({ "", "  ", "   ", "\t" }) .. table.concat(entries, " ") }
end

local function properties(rng)
  local indent = rng:pick({ "", "  ", "   " })
  local lines = { indent .. ":PROPERTIES:" }
  for _ = 1, rng:int(1, 4) do
    local key = rng:pick(PROPERTY_KEYS)
    local value = rng:pick(PROPERTY_VALUES)
    local line_indent = indent
    if rng:chance(0.2) then
      line_indent = indent .. " "
    end
    if value == "" then
      lines[#lines + 1] = line_indent .. ":" .. key .. ":"
    else
      lines[#lines + 1] = line_indent .. ":" .. key .. ": " .. value
    end
  end
  lines[#lines + 1] = indent .. ":END:"
  return lines
end

local function logbook(rng)
  local indent = rng:pick({ "", "  " })
  local lines = { indent .. ":LOGBOOK:" }
  for _ = 1, rng:int(1, 3) do
    lines[#lines + 1] = indent .. rng:pick(LOGBOOK_ENTRIES)
  end
  lines[#lines + 1] = indent .. ":END:"
  return lines
end

local function section_body(rng)
  local lines = {}
  for _ = 1, rng:int(0, 4) do
    local roll = rng:float()
    if roll < 0.2 then
      append(lines, rng:pick(LIST_BODIES))
    elseif roll < 0.35 then
      append(lines, rng:pick(TABLES))
    elseif roll < 0.55 then
      append(lines, rng:pick(BLOCKS))
    elseif roll < 0.6 then
      append(lines, rng:pick(INLINE_TASKS))
    elseif roll < 0.85 then
      append(lines, rng:pick(MISC))
    else
      lines[#lines + 1] = rng:pick(PARAGRAPHS)
    end
    if rng:chance(0.4) then
      lines[#lines + 1] = ""
    end
  end
  return lines
end

local function document(rng)
  local lines = {}
  append(lines, rng:pick(PREAMBLES))
  local level = 1
  for _ = 1, rng:int(1, 7) do
    lines[#lines + 1] = headline(rng, level)
    if rng:chance(0.6) then
      append(lines, planning(rng))
    end
    if rng:chance(0.5) then
      append(lines, properties(rng))
    end
    if rng:chance(0.25) then
      append(lines, logbook(rng))
    end
    append(lines, section_body(rng))
    level = math.max(1, math.min(6, level + rng:pick({ -1, 0, 0, 1, 1, 2 })))
  end
  return table.concat(lines, "\n") .. "\n"
end

-- `count` documents from `seed`, in generation order.
function M.documents(seed, count)
  local rng = new_rng(seed)
  local docs = {}
  for _ = 1, count do
    docs[#docs + 1] = document(rng)
  end
  return docs
end

return M
