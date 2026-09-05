-- match.parse + predicate: Emacs org-match query subset.
-- Run via: nvim --headless -l tests/match_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local m = require("organ.match")

local function pred(q)
  return m.predicate(q)
end

local function H(opts)
  return {
    todo_state = opts.todo,
    tags = opts.tags or {},
    level = opts.level or 1,
    title = opts.title or "",
    properties = opts.props or {},
    priority = opts.priority,
    file_path = opts.file_path,
    scheduled = opts.scheduled,
    deadline = opts.deadline,
    closed = opts.closed,
    category = opts.category,
  }
end

-- 1. Bare tag = require.
do
  local p = pred("work")
  assert(p(H({ tags = { "work" } })) == true, "tag matches")
  assert(p(H({ tags = { "home" } })) == false, "no tag mismatches")
end

-- 2. +/- tags compose with AND.
do
  local p = pred("+work-home")
  assert(p(H({ tags = { "work" } })) == true)
  assert(p(H({ tags = { "work", "home" } })) == false)
  assert(p(H({ tags = { "home" } })) == false)
end

-- 3. | gives OR between clauses.
do
  local p = pred("+work|+urgent")
  assert(p(H({ tags = { "work" } })) == true)
  assert(p(H({ tags = { "urgent" } })) == true)
  assert(p(H({ tags = { "leisure" } })) == false)
end

-- 4. /STATE narrows by TODO state.
do
  local p = pred("+work/+NEXT")
  assert(p(H({ tags = { "work" }, todo = "NEXT" })) == true)
  assert(p(H({ tags = { "work" }, todo = "TODO" })) == false)
  local q = pred("+work/-DONE")
  assert(q(H({ tags = { "work" }, todo = "TODO" })) == true)
  assert(q(H({ tags = { "work" }, todo = "DONE" })) == false)
end

-- 5. {regex} matches any tag.
do
  local p = pred("{^rev}")
  assert(p(H({ tags = { "review", "q3" } })) == true)
  assert(p(H({ tags = { "q3" }, title = "review" })) == false)
end

-- 5b. ITEM={regex} matches the headline title (Emacs special property).
do
  local p = pred("ITEM={review}")
  assert(p(H({ title = "Quarterly review" })) == true)
  assert(p(H({ title = "Status update", tags = { "review" } })) == false)
  local n = pred("-ITEM={review}")
  assert(n(H({ title = "Quarterly review" })) == false)
  assert(n(H({ title = "Status update" })) == true)
end

-- 6. LEVEL=N constraint.
do
  local p = pred("LEVEL=2")
  assert(p(H({ level = 2 })) == true)
  assert(p(H({ level = 3 })) == false)
  local q = pred("LEVEL>1")
  assert(q(H({ level = 2 })) == true)
  assert(q(H({ level = 1 })) == false)
end

-- 7. Property equality + numeric.
do
  local p = pred('PROP="foo"')
  assert(p(H({ props = { PROP = "foo" } })) == true)
  assert(p(H({ props = { PROP = "bar" } })) == false)
  local q = pred("EFFORT<60")
  assert(q(H({ props = { EFFORT = "30" } })) == true)
  assert(q(H({ props = { EFFORT = "90" } })) == false)
  -- Missing property reads as "" / 0 (Emacs `(or gv "")`).
  assert(q(H({})) == true)
  assert(pred('PROP=""')(H({})) == true)
  assert(pred('PROP="x"')(H({})) == false)
  assert(pred("EFFORT>0")(H({})) == false)
  assert(pred("EFFORT<60")(H({ props = { EFFORT = "1:30" } })) == true, "leading-number prefix")
end

-- 8. Combined clause: tag + property + level + todo.
do
  local p = pred("+work+EFFORT<60/+NEXT")
  assert(p(H({ tags = { "work" }, props = { EFFORT = "30" }, todo = "NEXT" })) == true)
  assert(p(H({ tags = { "work" }, props = { EFFORT = "30" }, todo = "TODO" })) == false)
end

-- Run `fn` under an instruction budget so a parser that stops advancing
-- fails instead of hanging the test.
local function bounded(fn)
  jit.off()
  debug.sethook(function()
    error("instruction budget exceeded")
  end, "", 1e7)
  local ok, res = pcall(fn)
  debug.sethook()
  jit.on()
  if not ok then
    error(res, 0)
  end
  return res
end

-- 9. Tag characters follow Emacs `org-tag-re` ([[:alnum:]_@#%] and any
-- non-ASCII); `&` is the explicit AND.
do
  local p = bounded(function()
    return pred("+#hash")
  end)
  assert(p(H({ tags = { "#hash" } })) == true)
  assert(p(H({ tags = { "hash" } })) == false)
  local q = bounded(function()
    return pred("+\228\187\149\228\186\139")
  end)
  assert(q(H({ tags = { "\228\187\149\228\186\139" } })) == true)
  local r = bounded(function()
    return pred("work&urgent-@home")
  end)
  assert(r(H({ tags = { "work", "urgent" } })) == true)
  assert(r(H({ tags = { "work", "urgent", "@home" } })) == false)
  assert(r(H({ tags = { "work" } })) == false)
  local s = bounded(function()
    return pred("+50%")
  end)
  assert(s(H({ tags = { "50%" } })) == true)
end

-- 10. A character outside the grammar raises instead of looping.
do
  local ok, err = pcall(function()
    return bounded(function()
      return m.parse("+a$b")
    end)
  end)
  assert(ok == false, "junk must error")
  assert(tostring(err):find("match:", 1, true), "error names the module: " .. tostring(err))
  assert(not tostring(err):find("budget", 1, true), "parser must not loop: " .. tostring(err))
end

-- 11. {regex} matches against the entry's tags, not the title.
do
  local p = pred("{^@}")
  assert(p(H({ tags = { "@home", "bar" }, title = "Call mom" })) == true)
  assert(p(H({ tags = { "bar" }, title = "@title" })) == false)
end

-- 12. A sign before {regex} applies to the regex term only.
do
  local p = pred("-{foo}bar")
  assert(p(H({ tags = { "@home", "bar" } })) == true)
  assert(p(H({ tags = { "foo", "bar" } })) == false)
  assert(p(H({ tags = { "@home" } })) == false)
end

-- 13. The TODO part is everything after the last `/`; `|` inside it
-- separates TODO alternatives.
do
  local p = pred("+work/NEXT|+@home")
  assert(p(H({ tags = { "@home", "bar" }, todo = "NEXT" })) == false)
  assert(p(H({ tags = { "@home", "bar" } })) == false)
  assert(p(H({ tags = { "work" }, todo = "NEXT" })) == true)
  assert(p(H({ tags = { "work" }, todo = "@home" })) == true)
  assert(p(H({ tags = { "work" }, todo = "TODO" })) == false)
  local q = pred("+work/-DONE|NEXT")
  assert(q(H({ tags = { "work" }, todo = "DONE" })) == false)
  assert(q(H({ tags = { "work" }, todo = "TODO" })) == true)
  -- A `/` inside a quoted value is not the TODO separator.
  local r = pred('PATH="/usr"')
  assert(r(H({ props = { PATH = "/usr" } })) == true)
  assert(r(H({ props = { PATH = "/etc" } })) == false)
end

-- 14. Property operand forms: quoted string compares as text, bare number
-- compares numerically, {regex} pattern-matches, `*` requires presence.
do
  assert(pred('PROP="10"')(H({ props = { PROP = "10" } })) == true)
  assert(pred("PROP=10")(H({ props = { PROP = "10.0" } })) == true)
  assert(pred('PROP<>"a"')(H({ props = { PROP = "b" } })) == true)
  assert(pred("PROP!=1")(H({ props = { PROP = "1" } })) == false)
  assert(pred("PROP={^ab}")(H({ props = { PROP = "abc" } })) == true)
  assert(pred("PROP<>{^ab}")(H({ props = { PROP = "abc" } })) == false)
  assert(pred('PROP=*""')(H({})) == false)
  assert(pred('PROP=*""')(H({ props = { PROP = "" } })) == true)
  assert(pred("effort<60")(H({ props = { Effort = "30" } })) == true, "names are case-insensitive")
  assert(pred(":work")(H({ tags = { "work" } })) == true, "`:` prefix means include")
end

-- 15. A blank `|` alternative matches nothing (Emacs `org-split-string`
-- drops leading and trailing separators).
do
  assert(pred("+work|")(H({ tags = { "home" } })) == false, "trailing |")
  assert(pred("|+work")(H({ tags = { "home" } })) == false, "leading |")
  assert(pred("+work|")(H({ tags = { "work" } })) == true)
  assert(pred("a||b")(H({ tags = { "b" } })) == true)
  assert(pred("a||b")(H({ tags = { "c" } })) == false)
  assert(pred("/TODO|")(H({ todo = "DONE" })) == false, "trailing | in the TODO part")
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("organ").setup({
  db_path = tmp .. "/m.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = { now_override = "2026-09-03T10:00" },
})

-- 16. A quoted timestamp operand compares as time (Emacs
-- `org-matcher-time` / `org-time<`), not as text.  Date-only values
-- are midnight; `<today>` is midnight of the pinned day; a side that
-- is not a timestamp never compares.
do
  local d = function(v)
    return H({ deadline = v })
  end
  assert(pred('DEADLINE<"<today>"')(d("<2099-01-01 Fri>")) == false, "lexical < would pass")
  assert(pred('DEADLINE<"<today>"')(d("<2026-09-02 Wed>")) == true)
  assert(pred('DEADLINE<"<today>"')(d("<2026-09-03 Thu>")) == false, "same midnight")
  assert(pred('DEADLINE>"<today>"')(d("<2000-01-01 Sat>")) == false)
  assert(pred('DEADLINE>"<today>"')(d("<2026-09-03 Thu 00:01>")) == true)
  assert(pred('DEADLINE<="<2026-09-03 Thu>"')(d("<2026-09-03 Thu 10:00>")) == false)
  assert(pred('DEADLINE>="<2026-09-03 Thu>"')(d("<2026-09-03 Thu 10:00>")) == true)
  assert(pred('DEADLINE="<2026-09-03 Thu>"')(d("[2026-09-03 Thu]")) == true, "brackets ignored")
  assert(pred('DEADLINE<>"<2026-09-03 Thu>"')(d("<2026-09-04 Fri>")) == true)
  assert(pred('DEADLINE<"<+1w>"')(d("<2026-09-09 Wed>")) == true)
  assert(pred('DEADLINE<"<+1w>"')(d("<2026-09-10 Thu>")) == false)
  assert(pred('DEADLINE<"<tomorrow>"')(d("<2026-09-03 Thu 23:59>")) == true)
  assert(pred('DEADLINE>"<yesterday>"')(d("<2026-09-02 Wed 00:01>")) == true)
  assert(pred('DEADLINE>="<-1d>"')(d("<2026-09-02 Wed>")) == true)
  assert(pred('DEADLINE<"<now>"')(d("<2026-09-03 Thu 09:59>")) == true)
  assert(pred('DEADLINE<"<now>"')(d("<2026-09-03 Thu 10:01>")) == false)
  assert(pred('DEADLINE<"<today>"')(H({})) == false, "missing property never compares")
  assert(pred('DEADLINE<>"<today>"')(H({})) == false, "missing property never compares (<>)")
  assert(pred('DEADLINE<"<today>"')(d("soon")) == false, "non-timestamp value never compares")
  assert(pred('DEADLINE="<2026-09-03>"')(d("2026-09-03")) == true, "bare dates parse")
  assert(pred('-DEADLINE<"<today>"')(d("<2026-09-02 Wed>")) == false, "negation applies")
  assert(pred('PROP<"<b>"')(H({ props = { PROP = "<a>" } })) == true, "not a time shape: text")
  assert(pred('PROP="<b>"')(H({ props = { PROP = "<a>" } })) == false, "not a time shape: text")
end

-- 17. PRIORITY reads as the configured default when the headline has no
-- cookie (Emacs `org-entry-get` returns `org-priority-default`).
do
  assert(pred('PRIORITY="B"')(H({})) == true)
  assert(pred('PRIORITY="A"')(H({})) == false)
  assert(pred('PRIORITY="A"')(H({ priority = "A" })) == true)
  assert(pred('PRIORITY<"C"')(H({})) == true)
  assert(pred('PRIORITY=*"B"')(H({})) == true, "the default counts as present")
end

-- 18. `/!` keeps entries whose state is active under the entry's own
-- `#+TODO` keywords: the buffer's for a sparse tree, the file's index
-- entry for agenda rows, the global config otherwise.
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "#+TODO: TODO WAIT | DONE", "* WAIT one" })
  local p = m.predicate("/!", { bufnr = b })
  assert(p(H({ todo = "WAIT" })) == true, "buffer keyword WAIT is active")
  assert(p(H({ todo = "DONE" })) == false)
  assert(p(H({})) == false)
  assert(m.predicate("/!")(H({ todo = "WAIT" })) == false, "WAIT is not a global keyword")
  assert(m.predicate("/!")(H({ todo = "TODO" })) == true)

  local path = tmp .. "/kw.org"
  vim.fn.writefile({ "#+TODO: TODO WAIT | DONE", "* WAIT one" }, path)
  require("organ.indexer").index_file_sync(path)
  local canon = require("organ.path").canonical(path)
  local g = m.predicate("/!")
  assert(g(H({ todo = "WAIT", file_path = canon })) == true, "file keyword WAIT is active")
  assert(g(H({ todo = "DONE", file_path = canon })) == false)
  assert(g(H({ todo = "WAIT", file_path = tmp .. "/none.org" })) == false, "unindexed: global")
end

-- 19. SCHEDULED / DEADLINE / CLOSED read the entry's planning line, never
-- a same-named drawer property (Emacs `org-special-properties`: a
-- `:DEADLINE:` drawer entry leaves `org-entry-get` returning nil).  An
-- entry with no planning compares as the empty string, so `DEADLINE=""`
-- selects exactly the entries that have no deadline.
do
  assert(pred('DEADLINE=""')(H({})) == true)
  assert(pred('DEADLINE=""')(H({ deadline = "<2026-08-01 Sat>" })) == false)
  assert(pred('DEADLINE<>""')(H({ deadline = "<2026-08-01 Sat>" })) == true)
  assert(pred('SCHEDULED=""')(H({ scheduled = "<2026-09-01 Tue>" })) == false)
  assert(pred('SCHEDULED=""')(H({ deadline = "<2026-09-01 Tue>" })) == true)
  assert(pred('CLOSED=""')(H({ closed = "[2026-09-02 Wed]" })) == false)
  assert(pred('CLOSED<>""')(H({ closed = "[2026-09-02 Wed]" })) == true)
  assert(pred("DEADLINE={2026}")(H({ deadline = "<2026-08-01 Sat>" })) == true)
  assert(pred('DEADLINE=*""')(H({})) == false, "absent, not empty")
  assert(
    pred('DEADLINE="<2026-08-01 Sat>"')(H({ props = { DEADLINE = "<2026-08-01 Sat>" } })) == false,
    "a drawer :DEADLINE: is not the special property"
  )
  assert(pred('DEADLINE=""')(H({ props = { DEADLINE = "<2026-08-01 Sat>" } })) == true)
end

-- 20. CATEGORY resolves the way Emacs `org-get-category` does: the
-- entry's own `:CATEGORY:` property first, then the file's
-- `#+CATEGORY:` keyword, then the file's basename.
do
  local cat_file = tmp .. "/cats.org"
  vim.fn.writefile({ "#+CATEGORY: cat1", "* one" }, cat_file)
  local plain = tmp .. "/plain.org"
  vim.fn.writefile({ "* one" }, plain)
  assert(pred('CATEGORY="own"')(H({ props = { CATEGORY = "own" } })) == true)
  assert(pred('CATEGORY="cat1"')(H({ file_path = cat_file })) == true)
  assert(pred('CATEGORY<>"cat1"')(H({ file_path = cat_file })) == false)
  assert(
    pred('CATEGORY="other"')(H({ props = { CATEGORY = "other" }, file_path = cat_file })) == true,
    "the entry's own property wins over the file keyword"
  )
  assert(pred('CATEGORY="plain"')(H({ file_path = plain })) == true, "basename fallback")
end

vim.fn.delete(tmp, "rf")
io.write("match ok\n")
os.exit(0)
