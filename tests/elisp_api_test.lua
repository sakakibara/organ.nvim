-- organ.elisp entry points: result shapes, never raising, the coroutine
-- entry, read and scan-sexps end positions, printed_length,
-- error_message, evaluation (ctx, call, consumer functions and macros,
-- subst_symbols) and to_value / to_lua.  Expected positions, lengths and
-- messages are what GNU Emacs 31.1 returns for the same input
-- (read-from-string, scan-sexps in an org-mode buffer and under
-- emacs-lisp-mode-syntax-table, (length (format "%S" ...)),
-- error-message-string, org-capture--expand-keyword-in-embedded-elisp
-- with org-store-link-plist bound), recorded here.
--
-- Run via: nvim --headless -l tests/elisp_api_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local elisp = require("organ.elisp")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function show(r)
  return vim.inspect(r, { depth = 3 }):gsub("\n%s*", " ")
end

local function read_value(src)
  local r = elisp.read(src)
  assert(r.ok, show(r))
  return r.value
end

local function printed(src)
  local p = elisp.prin1(read_value(src))
  return p.ok and p.value
end

local function printed_of(v)
  local p = elisp.prin1(v)
  return p.ok and p.value
end

-- The byte index of character position `p` (1-based) of `s`.
local function byte_of(s, p)
  local i, c = 1, 1
  while c < p and i <= #s do
    local b = s:byte(i)
    i = i + (b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4)
    c = c + 1
  end
  return i
end

-- result shapes

do
  local r = elisp.read("(a . b) tail")
  check(
    "read: ok result with value and next_pos",
    r.ok == true and r.value ~= nil and r.next_pos == 8,
    show(r)
  )
  r = elisp.read("(a")
  check(
    "read error: signal with symbol, data and text",
    r.ok == false
      and r.kind == "signal"
      and r.symbol == "end-of-file"
      and r.data == elisp.NIL
      and r.text == "(end-of-file)",
    show(r)
  )
  r = elisp.read(")")
  check(
    "invalid-read-syntax carries Emacs's data",
    r.kind == "signal" and r.text == "(invalid-read-syntax ))",
    show(r)
  )
  r = elisp.read("#s(foo)")
  check(
    "refusal: code and detail",
    r.ok == false and r.kind == "refused" and r.code == "syntax" and r.detail == "#s(",
    show(r)
  )
  r = elisp.read(string.rep("(", 500))
  check("limit: cap", r.ok == false and r.kind == "limit" and r.cap == "depth", show(r))
  for _, src in ipairs({ '"\\uD800"', '"\\xD800"', '"\\x110000"' }) do
    r = elisp.read(src)
    check("charset refusal of " .. src, r.kind == "refused" and r.code == "charset", show(r))
  end
  r = elisp.read("\255")
  check(
    "invalid UTF-8 source refuses charset",
    r.kind == "refused" and r.code == "charset",
    show(r)
  )
end

-- never raising

do
  local hostile = setmetatable({}, {
    __index = function()
      error("boom")
    end,
  })
  local r = elisp.read("1", 1, hostile)
  check(
    "a Lua error inside a call is refused internal",
    r.kind == "refused" and r.code == "internal" and tostring(r.detail):find("boom", 1, true) ~= nil,
    show(r)
  )
  r = elisp.prin1("not a value")
  check(
    "a non-value to prin1 is refused internal",
    r.kind == "refused" and r.code == "internal",
    show(r)
  )
  r = elisp.error_message({ ok = true })
  check(
    "error_message of a non-signal is refused internal",
    r.kind == "refused" and r.code == "internal",
    show(r)
  )
  for _, x in ipairs({
    print,
    coroutine.create(print),
    { 1, nil, 3 },
    { car = 1, extra = 2 },
    { 1, x = 2 },
  }) do
    r = elisp.to_value(x)
    check(
      "to_value of " .. type(x) .. " is a result",
      r.kind == "refused" and r.code == "internal",
      show(r)
    )
  end
end

-- coroutine entry: a caller near the end of its Lua stack still gets
-- the reader's full nesting, which the caller's own stack could not give

do
  local max = 0
  local function probe(n)
    max = n
    return 1 + probe(n + 1)
  end
  pcall(probe, 1)
  local function recurse(n)
    if n == 0 then
      return 0
    end
    return 1 + recurse(n - 1)
  end
  local nested = string.rep("(", 399) .. string.rep(")", 399)
  local nested_eval = string.rep("(progn ", 399) .. "1" .. string.rep(")", 399)
  local got, got_eval, direct
  local function deep(n)
    if n == 0 then
      direct = pcall(recurse, 400)
      got = elisp.read(nested)
      got_eval = elisp.eval_string(nested_eval)
      return 0
    end
    return 1 + deep(n - 1)
  end
  local ok = pcall(deep, max - 50)
  check("the caller's stack has no room for 400 more frames", ok and direct == false)
  check(
    "read of 399 levels from " .. (max - 50) .. " Lua frames deep",
    ok and got and got.ok and got.next_pos == #nested + 1,
    show(got)
  )
  check(
    "eval of 399 nested forms from " .. (max - 50) .. " Lua frames deep",
    ok and got_eval and got_eval.ok and got_eval.value == 1,
    show(got_eval)
  )
end

-- read: next_pos (Emacs's read-from-string end index, as a byte)

for _, case in ipairs({
  { "(a b) c", 5 },
  { "  foo bar", 5 },
  { '"x" 1', 3 },
  { "é x", 1 },
  { "'x", 2 },
  { "?a b", 2 },
  { "1.5)", 3 },
  { "(a)b", 3 },
  { "#x1F g", 4 },
  { '"é" z', 3 },
  { "; c\nfoo bar", 7 },
}) do
  local src, index = case[1], case[2]
  local r = elisp.read(src)
  local want = byte_of(src, index + 1)
  check(
    "read next_pos of " .. vim.inspect(src),
    r.ok and r.next_pos == want,
    show(r) .. " want " .. want
  )
end

do
  local r = elisp.read("a b c", 3)
  check("read from a later byte", r.ok and r.next_pos == 4 and printed("b") == "b", show(r))
end

-- scan_sexp: ends under the org and elisp syntax tables

local SCAN = {
  { "(a b) c", 6, 6 },
  { "  foo bar", 6, 6 },
  { '"a(b" x', 6, 6 },
  { '(a "b)" c) d', 11, 11 },
  { "'(x)", 5, 5 },
  { "'x y", 3, 3 },
  { "#'f", 4, 4 },
  { "(a (b) c", { "Unbalanced parentheses", 1, 9 }, { "Unbalanced parentheses", 1, 9 } },
  { "a)", 2, 2 },
  {
    ") b",
    { "Containing expression ends prematurely", 1, 2 },
    { "Containing expression ends prematurely", 1, 2 },
  },
  { "", false, false },
  { "   ", false, false },
  { "(\\) a)", 4, 7 },
  { "\\(a b", 2, 4 },
  { "foo\\ bar baz", 5, 9 },
  { "[a <b> c]", 10, 10 },
  { "<x y> z", 6, 3 },
  { "(é ü) ß", 6, 6 },
  { '"abc', { "Unbalanced parentheses", 1, 5 }, { "Unbalanced parentheses", 1, 5 } },
  { "a\\", 3, { "Unbalanced parentheses", 1, 3 } },
  { "{a} b", 4, 4 },
  { "$x$ y", 4, 4 },
  { "(a ;c\n b)", 10, 10 },
  { "?\\( x", 3, 4 },
  { "(x . y)", 8, 8 },
  { "`(a ,b) c", 8, 8 },
  { "?a", 3, 3 },
  { "x'y z", 4, 4 },
  { '%(format "%s" 1) rest', 2, 2 },
}

local function list_items(v)
  local out = {}
  while v ~= elisp.NIL do
    out[#out + 1] = v.car
    v = v.cdr
  end
  return out
end

for _, case in ipairs(SCAN) do
  local src = case[1]
  for i, tbl in ipairs({ "org", "elisp" }) do
    local want = case[i + 1]
    local r = elisp.scan_sexp(src, 1, tbl)
    local good
    if want == false then
      good = r.ok and r.value == elisp.NIL
    elseif type(want) == "number" then
      good = r.ok and r.value == byte_of(src, want)
    else
      local d = r.data and list_items(r.data) or {}
      good = r.kind == "signal"
        and r.symbol == "scan-error"
        and d[1]
        and d[1].s == want[1]
        and d[2] == want[2]
        and d[3] == want[3]
    end
    check(("scan_sexp %s %s"):format(tbl, vim.inspect(src)), good, show(r))
  end
end

do
  local r = elisp.scan_sexp("x", 1, "c")
  check("scan_sexp with an unknown table refuses", r.kind == "refused", show(r))
end

-- printed_length: (length (format "%S" FORM)) in characters

for _, case in ipairs({
  { "abc", 3 },
  { '"é∀"', 4 },
  { '"a\\nb"', 5 },
  { "1.5", 3 },
  { "'x", 2 },
  { '[1 "x"]', 7 },
  { "1180591620717411303424", 22 },
  { '"\\\\"', 4 },
  { "a\\ b", 4 },
}) do
  local r = elisp.printed_length(read_value(case[1]))
  check("printed_length " .. case[1], r.ok and r.value == case[2], show(r))
end

do
  local r = elisp.printed_length(read_value('"a\\nb"'), { escape_newlines = true })
  check("printed_length with escaped newlines", r.ok and r.value == 6, show(r))
end

-- princ: (format "%s" ...) prints strings and symbols without escapes

do
  local r = elisp.princ(read_value('("a\\"b" a\\ b 1.5 \'x)'))
  check("princ", r.ok and r.value == "(a\"b a b 1.5 'x)", show(r))
end

-- error_message of read and scan errors

for _, case in ipairs({
  { "(", "End of file during parsing" },
  { ")", 'Invalid read syntax: ")"' },
  { '"\\U00110000"', "Non-Unicode character: 0x110000" },
  { "?\\M", "Invalid escape char syntax: \\M not followed by -" },
}) do
  local r = elisp.read(case[1])
  local m = elisp.error_message(r)
  check("error_message of reading " .. case[1], m.ok and m.value == case[2], show(m))
end

do
  local r = elisp.scan_sexp("(a", 1, "elisp")
  local m = elisp.error_message(r)
  check(
    "error_message of a scan error",
    m.ok and m.value == 'Scan error: "Unbalanced parentheses", 1, 3',
    show(m)
  )
end

-- evaluation: results, ctx, call, consumer functions and macros

local function ev(src, ctx)
  return elisp.eval_string(src, ctx)
end

local function ev_printed(src, ctx)
  local r = ev(src, ctx)
  if not r.ok then
    return r
  end
  local p = elisp.prin1(r.value)
  return p.ok and p.value or p
end

do
  local r = ev("(cons 1 '(2)) trailing")
  check(
    "eval_string: value, trailing text ignored",
    r.ok and printed_of(r.value) == "(1 2)",
    show(r)
  )
  r = elisp.eval(read_value('(list \'a "b")'))
  check("eval of a read form", r.ok and printed_of(r.value) == '(a "b")', show(r))
  r = elisp.eval({ { sym = "car" }, { { sym = "quote" }, { 7, 8 } } })
  check("eval converts Lua data to a form", r.ok and r.value == 7, show(r))
  r = ev("(+ 1")
  check("eval_string reads first", r.kind == "signal" and r.symbol == "end-of-file", show(r))
  r = ev("(car 1)")
  check(
    "a signal: symbol name, data, text",
    r.kind == "signal"
      and r.symbol == "wrong-type-argument"
      and r.text == "(wrong-type-argument listp 1)"
      and printed_of(r.data) == "(listp 1)",
    show(r)
  )
  local m = elisp.error_message(r)
  check(
    "error_message of an eval signal",
    m.ok and m.value == "Wrong type argument: listp, 1",
    show(m)
  )
  m = elisp.error_message(ev("(signal 'foo nil)"))
  check(
    "error_message of Invalid error symbol",
    m.ok and m.value == "Invalid error symbol: foo",
    show(m)
  )
  m = elisp.error_message(ev('(error "boom")'))
  check("error_message of error", m.ok and m.value == "boom", show(m))
  r = ev("(funcall #'car)")
  check(
    "data holding a subr: text nil",
    r.kind == "signal"
      and r.symbol == "wrong-number-of-arguments"
      and r.text == nil
      and r.data.car.k == "fn",
    show(r)
  )
  r = ev("(funcall (lambda (x) x))")
  check("data holding a closure: text nil", r.kind == "signal" and r.text == nil, show(r))
  local props = { variables = { entry = { str = "x", props = true } } }
  r = ev("(error entry)", props)
  check(
    "error data holding a string with properties: text nil",
    r.kind == "signal" and r.text == nil,
    show(r)
  )
  r = ev("(signal 'error (list entry))", props)
  check(
    "signal data holding a string with properties: text nil",
    r.kind == "signal" and r.text == nil,
    show(r)
  )
  r = ev("(car entry)", props)
  check(
    "wrong-type-argument data holding a string with properties: text nil",
    r.kind == "signal" and r.text == nil,
    show(r)
  )
end

-- refusals of evaluation

for _, case in ipairs({
  { "(foo 1)", "function", "foo" },
  { "foo", "free-variable", "foo" },
  { "(setq foo 1)", "setq-global", "foo" },
  { "(let ((fill-column 1)) 1)", "special", "fill-column" },
  { "(signal 'quit nil)", "function", "quit" },
  { "(signal 'minibuffer-quit nil)", "function", "minibuffer-quit" },
  { "(signal 'iter-end-of-sequence nil)", "profile", "iter-end-of-sequence" },
  { "(diary-date 1 2 3)", "profile", "diary-date" },
  { "(calendar-iso-from-absolute 739913)", "function", "calendar-iso-from-absolute" },
  { '(format "%.100f" 1.0)', "precision", "100" },
  { '(error "it\'s")', "locale", "format-message" },
  { "(condition-case nil (car 1) ((error . x) 1))", "syntax", "dotted condition list" },
  { "(let ((x 1)) (lambda () (cond 1)))", "syntax", "cond clause in a closure" },
}) do
  local r = ev(case[1], { profile = "capture" })
  check(
    ("refuses %s: %s"):format(case[2], case[1]),
    r.kind == "refused" and r.code == case[2] and r.detail == case[3],
    show(r)
  )
end

-- nconc refuses a splice that would make a list reach itself, through
-- its cdrs or its elements, and condition-case does not catch the
-- refusal

for _, src in ipairs({
  "(let ((l (list 1 2))) (nconc l l))",
  "(let* ((l (list 1 2)) (m (list 0 l))) (nconc l (cdr l)))",
  "(let* ((l (list 1 2)) (m (cons 0 l))) (nconc l nil m))",
  "(let ((l (list 1))) (mapcan (lambda (x) l) '(1 2)))",
  "(let ((l (list 1 2))) (nconc l (list l)))",
  "(let ((l (list 1 2))) (nconc l (list 0 (vconcat (list 3 (list l))))))",
  "(let ((l (list 1 2))) (condition-case nil (nconc l l) (t 'caught)))",
}) do
  local r = ev(src)
  check(
    "nconc refuses a cycle: " .. src,
    r.kind == "refused" and r.code == "cycle" and r.detail == "nconc",
    show(r)
  )
end

-- mapconcat over a list a call shortens: Emacs reads results it never
-- stored (and aborts), so organ refuses; mapcar maps what is left.
do
  local src = '(let ((l (list "a" "b" "c"))) (%s (lambda (x) (delete "b" l) x) l%s))'
  local r = ev(src:format("mapconcat", ' "-"'))
  check(
    "mapconcat over a list shortened while mapping refuses",
    r.kind == "refused" and r.code == "cycle",
    show(r)
  )
  r = ev(src:format("mapcar", ""))
  check(
    "mapcar over a list shortened while mapping maps what is left",
    r.ok and printed_of(r.value) == '("a" "c")',
    show(r)
  )
end

do
  local r = ev("(let* ((l (list 1 2)) (m (list 3))) (nconc l m (list 4)) (list l m))")
  check(
    "nconc splices lists that share no cons",
    r.ok and printed_of(r.value) == "((1 2 3 4) (3 4))",
    show(r)
  )
  r = ev("(let* ((s (list 9)) (l (list 1 s)) (m (list s s))) (nconc l m) (length l))")
  check("nconc splices a list sharing elements with it", r.ok and r.value == 4, show(r))
  r = ev("(let ((l (list 1 2))) (nconc (list 0) l l))")
  check(
    "nconc of a list onto itself through a later argument refuses",
    r.kind == "refused" and r.code == "cycle",
    show(r)
  )
end

do
  local r =
    ev("(condition-case e (signal 'iter-end-of-sequence nil) (error 1))", { profile = "diary" })
  check(
    "an error symbol of the profile's features signals, outside `error'",
    r.kind == "signal" and r.symbol == "iter-end-of-sequence" and r.text == "(iter-end-of-sequence)",
    show(r)
  )
  r = ev("(diary-date 1 2 3)", { profile = "diary" })
  check(
    "a diary function exists in the diary profile and reads date",
    r.kind == "refused" and r.code == "free-variable" and r.detail == "date",
    show(r)
  )
  r = ev("(org-date 1 2 3)", { profile = "prefix" })
  check(
    "org-date in the prefix profile refuses where it calls diary-lib",
    r.kind == "refused" and r.code == "profile" and r.detail == "diary-date",
    show(r)
  )
  r = ev("(org-date 1 2)", { profile = "prefix" })
  check(
    "org-date in the prefix profile checks its argument count first",
    r.kind == "signal" and r.text == "(wrong-number-of-arguments (3 . 4) 2)",
    show(r)
  )
  r = ev("1", { profile = "nosuch" })
  check(
    "an unknown profile refuses internal",
    r.kind == "refused" and r.code == "internal",
    show(r)
  )
end

-- condition-case and ignore-errors catch signals only

for _, src in ipairs({
  "(condition-case nil (foo) (t 1))",
  "(ignore-errors (foo))",
  "(condition-case nil (signal 'quit nil) (t 1))",
}) do
  local r = ev(src)
  check("not caught: " .. src, r.kind == "refused", show(r))
end

-- ctx: profile binding, case_fold, variables

do
  local date = read_value("(10 24 2026)")
  local r = ev_printed("(list date entry)", { variables = { date = date, entry = "Meeting" } })
  check("ctx.variables are global values", r == '((10 24 2026) "Meeting")', show(r))
  r = ev_printed(
    "(let ((date 5)) (funcall '(lambda () date)))",
    { profile = "prefix", variables = { date = date } }
  )
  check(
    "a lexical let of a ctx variable does not bind it dynamically",
    r == "(10 24 2026)",
    show(r)
  )
  r = ev_printed(
    "(let ((date 5)) (funcall '(lambda () date)))",
    { profile = "diary", variables = { date = date } }
  )
  check("a dynamic let of a ctx variable binds it", r == "5", show(r))
  r = ev("(setq date 1)", { variables = { date = 1 } })
  check(
    "setq of a ctx variable refuses setq-global",
    r.kind == "refused" and r.code == "setq-global",
    show(r)
  )
  r = ev_printed(
    "(list case-fold-search (let ((case-fold-search nil)) case-fold-search))",
    { case_fold = true }
  )
  check("ctx.case_fold is case-fold-search", r == "(t nil)", show(r))
  r = ev_printed("(let ((x 1)) (funcall (lambda () x)))", { profile = "var" })
  check("lexical profile closure", r == "1", show(r))
  r = ev("(let ((x 1)) (funcall '(lambda () x)))", { profile = "var" })
  check(
    "a quoted lambda binds dynamically",
    r.kind == "refused" and r.code == "free-variable",
    show(r)
  )
  r = ev("(funcall (let ((tool-bar-map 1)) (lambda () tool-bar-map)))", { profile = "var" })
  check(
    "binding a special only some Emacs builds define refuses special",
    r.kind == "refused" and r.code == "special" and r.detail == "tool-bar-map",
    show(r)
  )
  r = ev("(condition-case nil (signal 'native-ice nil) (error 1))")
  check(
    "an error symbol only some Emacs builds define refuses profile",
    r.kind == "refused" and r.code == "profile" and r.detail == "native-ice",
    show(r)
  )
end

-- call: one builtin from Lua, as a direct call

do
  local r = elisp.call("identity", { 5 })
  check("call identity", r.ok and r.value == 5, show(r))
  r = elisp.call("list", { 1, "a", { sym = "b" } })
  check("call converts Lua arguments", r.ok and printed_of(r.value) == '(1 "a" b)', show(r))
  r = elisp.call("identity", { 1, 2 })
  check(
    "call: argument count data of a direct call",
    r.kind == "signal" and r.text == "(wrong-number-of-arguments identity 2)",
    show(r)
  )
  r = elisp.call("car", { 1 })
  check(
    "call: a builtin's signal",
    r.kind == "signal" and r.text == "(wrong-type-argument listp 1)",
    show(r)
  )
  r = elisp.call("calendar-day-of-week", { { 1, 1, 2024 } })
  check("call: a calendar builtin", r.ok and r.value == 1, show(r))
  r = elisp.call("calendar-iso-from-absolute", { 739913 })
  check(
    "call: a function outside the subset refuses",
    r.kind == "refused" and r.code == "function" and r.detail == "calendar-iso-from-absolute",
    show(r)
  )
  r = elisp.call("diary-date", { 1, 2, 3 })
  check(
    "call: a builtin outside the profile refuses",
    r.kind == "refused" and r.code == "profile",
    show(r)
  )
  r = elisp.call("quote", { 1 })
  check(
    "call: a special form is not a builtin",
    r.kind == "refused" and r.code == "function",
    show(r)
  )
end

-- call: format as a consumer formats a table cell or an agenda token

do
  local r = elisp.call("format", { "%5.2f|%-4s|%x", { float = 3.14159 }, "ab", 255 })
  check("call format", r.ok and r.value.s == " 3.14|ab  |ff", show(r))
  r = elisp.call("format", { "%s" })
  check(
    "call format: a signal",
    r.kind == "signal" and r.text == "(error Not enough arguments for format string)",
    show(r)
  )
  r = elisp.call("format", { "%5s", { str = "x", props = true } })
  check(
    "call format: the width of a string with properties refuses",
    r.kind == "refused" and r.code == "width",
    show(r)
  )
  r = elisp.call("format", { "%s|", { str = "x", props = true } })
  local p = r.ok and elisp.prin1(r.value)
  check(
    "call format: a string with properties gives one",
    p and p.kind == "refused" and p.code == "unprintable",
    show(p or r)
  )
  r = elisp.call("string-width", { "a\t" })
  check("call string-width of a TAB refuses", r.kind == "refused" and r.code == "width", show(r))
end

-- call: numbers, as Emacs's string-to-number, number-to-string and
-- arithmetic return them

do
  local r = elisp.call("string-to-number", { " 12abc" })
  check("call string-to-number", r.ok and r.value == 12, show(r))
  r = elisp.call("string-to-number", { "-1.5e3" })
  check("call string-to-number of a float", r.ok and printed_of(r.value) == "-1500.0", show(r))
  r = elisp.call("number-to-string", { { float = 1 } })
  check("call number-to-string of a float", r.ok and r.value.s == "1.0", show(r))
  r = elisp.call("number-to-string", { { bignum = "-1180591620717411303424" } })
  check(
    "call number-to-string of a bignum",
    r.ok and r.value.s == "-1180591620717411303424",
    show(r)
  )
  r = elisp.call("*", { 9007199254740991, 2 })
  local l = r.ok and elisp.to_lua(r.value)
  check(
    "a product beyond 2^53 converts to a bignum table",
    l and l.ok and vim.deep_equal(l.value, { bignum = "18014398509481982" }),
    show(l or r)
  )
  r = elisp.call("-", { { bignum = "9007199254740992" }, 1 })
  check(
    "a bignum result within 2^53 is a Lua number",
    r.ok and r.value == 9007199254740991,
    show(r)
  )
  r = elisp.call("+", { 0.5, 2 })
  check("a non-integral Lua number is a float", r.ok and printed_of(r.value) == "2.5", show(r))
  r = elisp.call("number-to-string", { 0 / 0 })
  check("printing a NaN refuses", r.kind == "refused" and r.code == "nan", show(r))
  r = elisp.call("eq", { "a", "a" })
  check("eq of two equal strings refuses", r.kind == "refused" and r.code == "eq-identity", show(r))
  r = elisp.call("equal", { "a", "a" })
  check("equal of two equal strings", r.ok and r.value == elisp.T, show(r))
end

-- consumer functions and macros

do
  local seen
  local ctx = {
    functions = {
      ["org-entry-get"] = {
        fn = function(argv, cx)
          seen = argv
          return { "v", argv.n }
        end,
      },
      boom = {
        fn = function(argv, cx)
          cx.signal("wrong-type-argument", { { sym = "stringp" }, argv[1] or 0 })
        end,
      },
      no = {
        fn = function(argv, cx)
          cx.refuse("holidays", "no holidays")
        end,
      },
      badcode = {
        fn = function(argv, cx)
          cx.refuse("nosuch", "x")
        end,
      },
      nested = {
        fn = function(argv, cx)
          return cx.eval(argv[1])
        end,
      },
      luaerr = {
        fn = function()
          error("consumer bug")
        end,
      },
    },
    macros = {
      ["org-sbe"] = {
        fn = function(argv, cx)
          seen = argv
          return argv[2]
        end,
      },
    },
  }
  local r = ev_printed('(org-entry-get (car \'(1)) "P")', ctx)
  check(
    "a consumer function gets evaluated arguments",
    r == '("v" 2)' and seen.n == 2 and seen[1] == 1,
    show(r)
  )
  r = ev_printed("(funcall 'org-entry-get 1)", ctx)
  check("funcall of a consumer function", r == '("v" 1)', show(r))
  r = ev_printed('(org-sbe "blk" (n $2))', ctx)
  check(
    "a consumer macro gets the argument forms",
    r == "(n $2)" and seen.n == 2 and seen[1].k == "str",
    show(r)
  )
  r = ev("(funcall 'org-sbe 1)", ctx)
  check(
    "funcall of a consumer macro is invalid-function",
    r.kind == "signal" and r.text == "(invalid-function org-sbe)",
    show(r)
  )
  r = ev_printed("(condition-case e (boom 3) (wrong-type-argument (list 'caught e)))", ctx)
  check(
    "cx.signal is caught by condition-case",
    r == "(caught (wrong-type-argument stringp 3))",
    show(r)
  )
  r = ev("(condition-case nil (no) (t 1))", ctx)
  check(
    "cx.refuse is a refusal condition-case does not catch",
    r.kind == "refused" and r.code == "holidays" and r.detail == "no holidays",
    show(r)
  )
  r = ev("(badcode)", ctx)
  check(
    "cx.refuse of an unknown code refuses internal",
    r.kind == "refused" and r.code == "internal",
    show(r)
  )
  r = ev("(condition-case nil (luaerr) (t 1))", ctx)
  check(
    "a consumer's Lua error refuses internal, uncaught",
    r.kind == "refused" and r.code == "internal" and r.detail:find("consumer bug", 1, true) ~= nil,
    show(r)
  )
  r = ev_printed("(let ((x 5)) (nested '(list x)))", ctx)
  check("cx.eval sees the dynamic bindings", r == "(5)", show(r))
  r = ev("(let ((x 5)) (nested '(list x)))", { profile = "capture", functions = ctx.functions })
  check(
    "cx.eval starts a fresh lexical environment",
    r.kind == "refused" and r.code == "free-variable",
    show(r)
  )
  local budget = {}
  r = ev("(progn (org-entry-get) (org-entry-get))", { functions = ctx.functions, budget = budget })
  check(
    "each consumer call is charged at least 1 000 steps",
    r.ok and budget.steps >= 2000,
    show(budget)
  )
end

do
  local function sleeper(ms, timeout)
    return {
      fn = function()
        vim.uv.sleep(ms)
        return 0
      end,
      timeout = timeout,
    }
  end
  local r =
    ev("(progn (slow) (slow))", { caps = { time = 30 }, functions = { slow = sleeper(20) } })
  check("a consumer call's wall time counts", r.kind == "limit" and r.cap == "time", show(r))
  r =
    ev("(progn (slow) (slow))", { caps = { time = 30 }, functions = { slow = sleeper(20, 1000) } })
  check("spec.timeout keeps a consumer call's wall time out", r.ok, show(r))
  local steps_used
  r = ev("(spend)", {
    caps = { steps = 5000 },
    functions = {
      spend = {
        fn = function(_, cx)
          steps_used = true
          cx.charge(10000, 0)
          return 0
        end,
      },
    },
  })
  check(
    "cx.charge counts against the caps",
    steps_used and r.kind == "limit" and r.cap == "steps",
    show(r)
  )
end

-- subst_symbols (org-capture--expand-keyword-in-embedded-elisp)

do
  local plist = { [":link"] = "L", [":desc"] = false, [":x"] = { { sym = "a" }, { sym = "b" } } }
  for _, case in ipairs({
    {
      '(f %:link (g %:desc) [%:link] "%:link" a%:linkb b%:link%:x)',
      '(f "L" (g %:desc) [%:link] "%:link" a%:linkb b%:link%:x)',
    },
    { "(f x%:link\\\ny)", '(f "L")' },
    { "%:link", '"L"' },
    { "[%:link]", "[%:link]" },
    { "(%:x %:x)", "((a b) (a b))" },
    { "(f %:li\\nk)", '(f "L")' },
    { "(f %%:link :link %:)", '(f "L" :link %:)' },
    { "(a . %:link)", "!! (wrong-type-argument listp %:link)" },
    { "((x . y) . z)", "!! (wrong-type-argument listp z)" },
  }) do
    local r = elisp.subst_symbols(read_value(case[1]), plist)
    local got = r.ok and printed_of(r.value) or (r.kind == "signal" and "!! " .. r.text) or show(r)
    check("subst_symbols " .. vim.inspect(case[1]), got == case[2], got)
  end
  local r = elisp.subst_symbols(read_value("(%:x %:x)"), plist)
  check(
    "subst_symbols puts one value at each use",
    r.ok and r.value.car == r.value.cdr.car,
    show(r)
  )
  local form = read_value("(a (b))")
  r = elisp.subst_symbols(form, {})
  check(
    "subst_symbols builds fresh conses",
    r.ok and r.value ~= form and r.value.cdr ~= form.cdr,
    show(r)
  )
  r = elisp.subst_symbols(form, "x")
  check(
    "subst_symbols with a non-table plist refuses internal",
    r.kind == "refused" and r.code == "internal",
    show(r)
  )
end

-- to_value / to_lua

do
  local cases = {
    { 1, 1 },
    { -0.0, 0 },
    { 2 ^ 53, { float = 2 ^ 53 } },
    { 1.5, { float = 1.5 } },
    { "é", "é" },
    { true, true },
    { false, {} },
    { {}, {} },
    { { 1, "a", { sym = "b" } }, { 1, "a", { sym = "b" } } },
    { { car = 1, cdr = 2 }, { car = 1, cdr = 2 } },
    {
      { bignum = "-123456789012345678901234567890" },
      { bignum = "-123456789012345678901234567890" },
    },
    { { bignum = "42" }, 42 },
    { { vector = { 1, { 2 } } }, { vector = { 1, { 2 } } } },
    { { str = "x", props = true }, { str = "x", props = true } },
    { { float = 0 / 0 }, nil },
  }
  for i, c in ipairs(cases) do
    local v = elisp.to_value(c[1])
    local back = v.ok and elisp.to_lua(v.value)
    local good = back and back.ok
    if good and c[2] ~= nil then
      good = vim.deep_equal(back.value, c[2])
    elseif good then
      good = back.value.float ~= back.value.float
    end
    check("to_value/to_lua round trip " .. i, good, show(back or v))
  end
  local p =
    elisp.prin1(elisp.to_value({ 1, { sym = "a b" }, { car = "s", cdr = { sym = "x" } } }).value)
  check("to_value builds printable values", p.ok and p.value == '(1 a\\ b ("s" . x))', show(p))
  local cyc = {}
  cyc[1] = cyc
  local r = elisp.to_value(cyc)
  check(
    "to_value of a cyclic table refuses cycle",
    r.kind == "refused" and r.code == "cycle",
    show(r)
  )
  r = elisp.to_value("\255")
  check(
    "to_value of invalid UTF-8 refuses charset",
    r.kind == "refused" and r.code == "charset",
    show(r)
  )
  local shared = { 1 }
  local v = elisp.to_value({ shared, shared }).value
  check("to_value keeps sharing", v.car == v.cdr.car)
  local l = elisp.to_lua(v).value
  check("to_lua keeps sharing", l[1] == l[2])
  r = elisp.to_lua("not a value")
  check("to_lua of a non-value is a result", r.kind == "refused" and r.code == "internal", show(r))
  local improper = elisp.to_lua(read_value("(a b . c)")).value
  check(
    "to_lua of an improper list",
    vim.deep_equal(
      improper,
      { car = { sym = "a" }, cdr = { car = { sym = "b" }, cdr = { sym = "c" } } }
    ),
    show(improper)
  )
end

-- diary: XT-10 applies to a whole diary sexp only; org-class asks the
-- consumer for holidays, and refuses without it where they matter

do
  local date = read_value("(10 24 2026)")
  local vars = { date = date, entry = "Ent" }
  local diary = { profile = "diary", variables = vars }
  check(
    "XT-10 reads a year-first triple of a diary sexp",
    ev_printed("(diary-date 2026 10 24)", diary) == '(nil . "Ent")'
  )
  local r = elisp.call("diary-date", { 2026, 10, 24 }, diary)
  check("XT-10 does not apply to call", r.ok and r.value == elisp.NIL, show(r))
  r = ev("(diary-anniversary 10 24 2025.0)", { profile = "diary", variables = { date = date } })
  check(
    "diary-anniversary reads entry before the ordinal suffix",
    r.kind == "refused" and r.code == "free-variable" and r.detail == "entry",
    show(r)
  )
  local own = {
    ["diary-date"] = {
      fn = function(argv)
        return argv[1]
      end,
    },
  }
  r = ev("(diary-date 2026 10 24)", { profile = "diary", variables = vars, functions = own })
  check("XT-10 leaves a consumer's diary-date alone", r.ok and r.value == 2026, show(r))

  local seen = {}
  local function holidays(names)
    return {
      ["calendar-check-holidays"] = {
        fn = function(argv)
          seen[#seen + 1] = printed_of(argv[1])
          return names
        end,
      },
    }
  end
  local class = "(org-class 2026 9 1 2026 12 31 6 %s)"
  local function with(names, skip, profile)
    return ev_printed(
      class:format(skip),
      { profile = profile or "diary", variables = vars, functions = holidays(names) }
    )
  end
  check("org-class skips a holiday", with({ "Day" }, "'holidays") == "nil")
  check("org-class skips a named holiday", with({ "Day" }, '"Day"') == "nil")
  check("org-class keeps a date no holiday falls on", with({}, "'holidays") == '"Ent"')
  check("org-class keeps another holiday", with({ "Day" }, '"Night"') == '"Ent"')
  check("org-class asks with skip weeks only", with({ "Day" }, "1") == '"Ent"')
  check("org-class asks in the prefix profile", with({ "Day" }, "'holidays", "prefix") == "nil")
  check("org-class passes date", seen[1] == "(10 24 2026)", vim.inspect(seen))
  for _, case in ipairs({
    { "'holidays", "diary", "holidays" },
    { '"Day"', "diary", "holidays" },
    { "1", "prefix", "profile" },
  }) do
    r = ev(class:format(case[1]), { profile = case[2], variables = vars })
    check(
      "org-class without the consumer refuses: " .. case[1] .. " " .. case[2],
      r.kind == "refused" and r.code == case[3] and r.detail == "calendar-check-holidays",
      show(r)
    )
  end
  check(
    "org-class without holidays: skip weeks alone",
    ev_printed(class:format("1"), diary) == '"Ent"'
  )
  for _, d in ipairs({ "(10 24 10026)", "(2 30 2026)" }) do
    r = ev(
      "(org-class 1 1 1 99999 12 31 6 1)",
      { profile = "diary", variables = { date = read_value(d), entry = "Ent" } }
    )
    check(
      "org-class refuses holidays on a date they may not finish on: " .. d,
      r.kind == "refused" and r.code == "holidays",
      show(r)
    )
  end
end

-- time: ctx.now, and refusals the conformance corpus cannot hold
-- because Emacs's answer differs by platform, by earlier calls, or
-- aborts Emacs

do
  local function now()
    return 1700000000, 123456789
  end
  local r = ev_printed(
    '(list (current-time) (float-time) (format-time-string "%s %N" nil t))',
    { now = now }
  )
  check(
    "ctx.now is the time nil stands for",
    r == '((25939 61696 123456 789000) 1700000000.1234567 "1700000000 123456789")',
    show(r)
  )
  r = ev_printed("(time-subtract nil nil)", { now = now })
  check("(time-subtract nil nil) is (0 0 0 0)", r == "(0 0 0 0)", show(r))
  local function refused(label, src, code, detail)
    local e = ev(src)
    check(
      label,
      e.ok == false
        and e.kind == "refused"
        and e.code == code
        and (not detail or e.detail == detail),
      show(e)
    )
  end
  refused(
    "%Z of UTC (GMT on glibc, UTC on macOS)",
    '(format-time-string "%Z" 0 t)',
    "locale",
    "format-time-string %Z of UTC"
  )
  refused("%Z of zone 0", '(format-time-string "%Z" 0 0)', "locale")
  refused(
    "a space-padded signed number wider than its width (Emacs aborts)",
    '(format-time-string "%_1z" 0 -18000)',
    "precision"
  )
  refused(
    "a negative year space-padded to its width",
    '(format-time-string "%_Y" -400000000000 t)',
    "precision"
  )
  refused(
    "a negative %s space-padded at its default width",
    '(format-time-string "%_s" -1 t)',
    "precision"
  )
  refused(
    "a negative century of many digits under + and _",
    '(format-time-string "%+_5C" -24875530938887812 t)',
    "precision"
  )
  refused(
    "a colon offset space-padded below its length",
    '(format-time-string "%_6::z" 0 -18000)',
    "precision"
  )
  refused(
    "an overlap with no DST flag (gnulib keeps its guess from the last call)",
    '(encode-time \'(0 30 1 3 11 2024 nil -1 "America/New_York"))',
    "locale",
    "local time in a daylight saving transition"
  )
  refused(
    "a DST flag no nearby time has (glibc moves an hour back)",
    '(encode-time \'(0 0 0 1 1 2024 nil t "UTC"))',
    "locale",
    "DST flag the zone does not use nearby"
  )
  refused("an offset glibc caps at 24 hours", "(decode-time 0 90000)", "locale")
  refused("a POSIX rule before 1970", '(decode-time -315619200 "XST5XDT,M3.2.0,M11.1.0")', "locale")
  refused("a POSIX rule past 2569", '(decode-time 20000000000 "XST5XDT,M3.2.0,M11.1.0")', "locale")
  refused(
    "a POSIX rule early in 1970 in the south",
    '(decode-time 0 "NZST-12NZDT,M9.5.0,M4.1.0/3")',
    "locale"
  )
  refused("a POSIX string without rules", '(decode-time 0 "XST5XDT")', "locale")
  refused("a name glibc rejects", '(decode-time 0 \'(3600 "XY"))', "locale")
  local e = ev('(decode-time 0 \'(3600 "ABC"))')
  check("a three-letter zone name", e.ok, show(e))
  e = ev('(encode-time \'(0 30 1 3 11 2024 nil nil "America/New_York"))')
  check("an overlap with a DST flag", e.ok, show(e))
end

-- an entry point called while a call runs (from a consumer function)
-- is nested in that call: it shares its caps, budget and depth

do
  local function internal(r)
    return r.ok == false and r.kind == "refused" and r.code == "internal"
  end
  local levels = 0
  local ctx
  ctx = {
    functions = {
      f = {
        fn = function()
          levels = levels + 1
          local r = elisp.eval_string("(f)", ctx)
          return r.ok and r.value or 0
        end,
      },
    },
  }
  local r = ev("(f)", ctx)
  check(
    ("re-entering recursion ends in the depth limit (%d levels)"):format(levels),
    r.kind == "limit" and r.cap == "depth" and levels < 400,
    show(r)
  )

  local inner
  local inner_budget = {}
  r = ev("(progn (f) 1)", {
    caps = { steps = 5000 },
    functions = {
      f = {
        fn = function()
          inner = elisp.eval_string("(while t)", { budget = inner_budget })
          return 0
        end,
      },
    },
  })
  check(
    "a nested call gets only the caller's remaining steps, and its limit stays with the caller",
    inner
      and inner.kind == "limit"
      and inner.cap == "steps"
      and inner_budget.steps <= 5000
      and r.kind == "limit"
      and r.cap == "steps",
    show(inner) .. " / " .. show(r) .. " " .. vim.inspect(inner_budget)
  )

  local budget = {}
  local shared = { budget = budget }
  shared.functions = {
    f = {
      fn = function()
        return elisp.eval_string("(let ((i 0)) (while (< i 100) (setq i (1+ i))) i)", shared).value
      end,
    },
  }
  r = ev("(f)", shared)
  local alone = {}
  ev("(let ((i 0)) (while (< i 100) (setq i (1+ i))) i)", { budget = alone })
  check(
    "a nested call charges a budget it shares with its caller once",
    r.ok and r.value == 100 and budget.steps < alone.steps + 2000,
    show(r) .. " " .. vim.inspect(budget) .. " " .. vim.inspect(alone)
  )

  -- coroutine.yield from a consumer function
  budget = {}
  r = ev("(+ 1 (f))", {
    budget = budget,
    functions = {
      f = {
        fn = function()
          coroutine.yield(true, { ok = true, value = 99 })
        end,
      },
    },
  })
  check(
    "a consumer function that yields gives refused internal, charged",
    internal(r) and (budget.steps or 0) >= 1000,
    show(r) .. " " .. vim.inspect(budget)
  )
  r = ev("(+ 1 2)")
  check("an entry after a yielding consumer is not nested in it", r.ok and r.value == 3, show(r))

  -- cx.eval unwinds its bindings when the consumer catches its error
  local catching = {
    fn = function(_, cx)
      pcall(cx.eval, read_value('(let ((x 2) (case-fold-search t)) (error "boom"))'))
      return 0
    end,
  }
  for _, profile in ipairs({ "table", "var" }) do
    r = ev("(let ((x 1) (case-fold-search nil)) (f) (list x case-fold-search))", {
      profile = profile,
      functions = { f = catching },
    })
    check(
      "cx.eval unwinds let bindings when its error is caught (" .. profile .. ")",
      r.ok and printed_of(r.value) == "(1 nil)",
      show(r)
    )
  end
  r = ev("(let ((i 0)) (while (< i 150) (f) (setq i (1+ i))) i)", {
    caps = { depth = 20 },
    functions = { f = catching },
  })
  check("cx.eval restores the depth when its error is caught", r.ok and r.value == 150, show(r))

  -- misuse by a consumer or a ctx is refused internal
  local function consumer(fn)
    return { functions = { f = { fn = fn } } }
  end
  local misuse = {
    {
      "a limit of an unknown cap",
      "(f)",
      consumer(function()
        error({ elisp = "limit", cap = "bogus" })
      end),
    },
    {
      "a refusal with an unknown code",
      "(f)",
      consumer(function()
        error({ elisp = "refused", code = "made-up" })
      end),
    },
    {
      "a signal of an unknown error symbol",
      "(condition-case nil (f) (error 1))",
      consumer(function()
        error({
          elisp = "signal",
          symbol = { k = "sym", name = { k = "str", s = "nope" } },
          data = elisp.NIL,
        })
      end),
    },
    {
      "a signal with malformed data, even inside condition-case",
      "(condition-case e (f) (error e))",
      consumer(function()
        error({ elisp = "signal", symbol = elisp.read("error").value, data = {} })
      end),
    },
    {
      "a limit of an unknown cap raised by ctx.now",
      "(current-time)",
      {
        now = function()
          error({ elisp = "limit", cap = "bogus" })
        end,
      },
    },
    {
      "a negative charge",
      "(progn (f) (while t))",
      consumer(function(_, cx)
        cx.charge(-2e7, 0)
        return 1
      end),
    },
    {
      "a NaN charge",
      "(f)",
      consumer(function(_, cx)
        cx.charge(0 / 0)
        return 1
      end),
    },
    {
      "a cyclic list",
      "(length (f))",
      consumer(function()
        local c = { k = "cons", car = 1 }
        c.cdr = c
        return c
      end),
    },
    {
      "a cons without a car",
      "(car (f))",
      consumer(function()
        return { k = "cons", cdr = elisp.NIL }
      end),
    },
    { "a NaN cap", "(while t)", { caps = { steps = 0 / 0 } } },
    { "a negative cap", "(+ 1 2)", { caps = { steps = -1 } } },
    { "a cap that is not a number", "(+ 1 2)", { caps = { depth = "9" } } },
    { "a NaN budget", "(while t)", { budget = { steps = 0 / 0 } } },
    { "a negative budget", "(while t)", { budget = { steps = -3e7 } } },
    { "an infinite budget", "(+ 1 2)", { budget = { time = math.huge } } },
    {
      "ctx.now with nanoseconds past 1e9",
      "(current-time)",
      {
        now = function()
          return 1, 2e9
        end,
      },
    },
    {
      "ctx.now with a fraction",
      "(current-time)",
      {
        now = function()
          return 1.5, 0
        end,
      },
    },
    { "ctx.now that is not a function", "(current-time)", { now = 5 } },
  }
  for _, m in ipairs(misuse) do
    local t0 = vim.uv.hrtime()
    r = ev(m[2], m[3])
    local ms = (vim.uv.hrtime() - t0) / 1e6
    check(m[1] .. " is refused internal", internal(r) and ms < 2000, show(r))
  end
  r = elisp.eval_string("(+ 1 2)", { caps = { steps = math.huge } })
  check("an infinite cap clamps to the default", r.ok and r.value == 3, show(r))
  r = elisp.call("list", { 1, nil, 3 })
  check("call with an args array with holes is refused internal", internal(r), show(r))
  for _, pos in ipairs({ 1.5, 0, 5, "1" }) do
    r = elisp.scan_sexp("(a)", pos, "elisp")
    check("scan_sexp at position " .. tostring(pos) .. " is refused internal", internal(r), show(r))
    r = elisp.read("(a)", pos)
    check("read at position " .. tostring(pos) .. " is refused internal", internal(r), show(r))
  end
  r = elisp.read("(a)", 4)
  check(
    "read at the end of the text is end-of-file",
    r.kind == "signal" and r.symbol == "end-of-file",
    show(r)
  )
end

-- error text: error_message obeys the string cap, and a signal's text is
-- printed under the call's caps and budget

do
  local e = ev('(signal \'error (list "m" (make-string 600000 ?\\")))')
  local m = elisp.error_message(e)
  check(
    "error_message longer than the string cap is a string limit",
    e.kind == "signal" and m.ok == false and m.kind == "limit" and m.cap == "string",
    show(m)
  )
  local budget = {}
  e = ev("(signal 'error (number-sequence 1 3000))", { caps = { steps = 5000 }, budget = budget })
  check(
    "printing a signal's text past the call's step cap is a steps limit",
    e.kind == "limit" and e.cap == "steps" and budget.steps > 5000,
    show(e) .. " " .. vim.inspect(budget)
  )
  e = ev("(signal 'error (list (make-string 600000 ?a) (make-string 600000 ?a)))")
  check(
    "a signal's text past the string cap is a string limit",
    e.kind == "limit" and e.cap == "string",
    show(e)
  )
  e = ev("(signal 'error (list 1 (lambda (x) x)))", { profile = "var" })
  check(
    "a signal whose data holds a closure has no text",
    e.kind == "signal" and e.text == nil,
    show(e)
  )
  e = ev("(let ((x 1)) (dotimes (i 199) (setq x (list x))) (signal 'error (list x)))")
  check(
    "a signal whose data Emacs's printer cannot print has no text",
    e.kind == "signal" and e.text == nil,
    show(e)
  )
  e = ev("(signal 'error (number-sequence 1 3))", { caps = { steps = 5000 } })
  check("a short signal's text is printed", e.text == "(error 1 2 3)", show(e))
end

-- sort writes back along the list as it is after sorting, and refuses
-- where Emacs would read past its array or a list would reach itself

do
  local cases = {
    {
      "a predicate that lengthens the list",
      "(let ((l (list 3 2 1)) (m (list 7 8)) (done nil)) (sort l (lambda (a b) (unless done (setq done t) (nconc l m)) (< a b))))",
    },
    {
      "a predicate that makes an element hold the list",
      "(let* ((e (list 9)) (l (list e 1)) (done nil)) (sort l (lambda (a b) (unless done (setq done t) (nconc e (list (cdr l)))) (eql a 1))) 0)",
    },
    {
      "an element sharing the list's tail",
      "(let* ((tl (list 1)) (l (cons tl tl))) (sort l (lambda (a b) (consp b))) 0)",
    },
  }
  for _, c in ipairs(cases) do
    local r = ev(c[2])
    check("sort: " .. c[1] .. " refuses cycle", r.kind == "refused" and r.code == "cycle", show(r))
  end
  check(
    "sort: a predicate that shortens the list writes what is left",
    ev_printed("(let ((l (list 3 2 1 5 4))) (list (sort l (lambda (a b) (delq 1 l) (< a b))) l))")
      == "((1 2 3 4) (1 2 3 4))"
  )
end

-- XT-10 reads year-first only arguments written as decimal integers;
-- eval of a form value, which has no spelling, only fixnum arguments

do
  local diary = { profile = "diary", variables = { date = read_value("(2 29 2024)"), entry = "E" } }
  local function xt10(r)
    return r.ok and printed_of(r.value) == '(nil . "E")'
  end
  check("eval_string: decimal spellings read year-first", xt10(ev("(diary-date 2024 2 29)", diary)))
  for _, src in ipairs({
    "(diary-date #x7e8 2 29)",
    "(diary-date #24r3c8 2 29)",
    "(diary-date 2024.0 2 29)",
    "(diary-date 2024. 2 29)",
  }) do
    local r = ev(src, diary)
    check("eval_string: " .. src .. " follows Emacs", r.ok and r.value == elisp.NIL, show(r))
  end
  local r = elisp.eval(read_value("(diary-date 2024 2 29)"), diary)
  check("eval: fixnum arguments read year-first", xt10(r), show(r))
  r = elisp.eval(read_value("(diary-date 2024.0 2 29)"), diary)
  check("eval: a float argument follows Emacs", r.ok and r.value == elisp.NIL, show(r))
end

-- ctx.syntax_table: the word syntax capitalize and upcase-initials use

do
  local function cap(s, syntax_table)
    return ev_printed(
      ("(capitalize %q)"):format(s),
      { profile = "prefix", syntax_table = syntax_table }
    )
  end
  check("the org syntax table is the default", cap("it's") == '"It\'s"', tostring(cap("it's")))
  check("org: ' is a word constituent", cap("it's", "org") == '"It\'s"')
  check(
    "agenda: ' is not a word constituent",
    cap("it's", "agenda") == '"It\'S"',
    tostring(cap("it's", "agenda"))
  )
  local r = ev('(upcase-initials "a\u{b7}b")', { syntax_table = "agenda" })
  check(
    "agenda: U+00B7 is not a word constituent",
    r.ok and printed_of(r.value) == '"A\u{b7}B"',
    show(r)
  )
  for _, bad in ipairs({ "elisp", "Agenda", 1 }) do
    r = ev('(capitalize "a")', { syntax_table = bad })
    check(
      "syntax_table " .. tostring(bad) .. " is refused internal",
      r.ok == false and r.kind == "refused" and r.code == "internal",
      show(r)
    )
  end
  r = elisp.scan_sexp("(a)", 1, "agenda")
  check("scan_sexp does not take the agenda table", r.ok == false and r.kind == "refused", show(r))
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nelisp api: all checks passed")
os.exit(0)
