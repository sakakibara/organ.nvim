-- Constructors + validate accept the inline-object node kinds.
-- Run via: nvim --headless -l tests/ast_inline_nodes_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast.init")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

-- Each constructor produces the documented shape.
local e = A.entity("copy")
check(e.kind == "entity" and e.name == "copy", "entity: name field")

local sub = A.subscript({ A.text("i") })
check(sub.kind == "subscript" and sub.content[1].text == "i", "subscript: content field")

local sup = A.superscript({ A.text("2") })
check(sup.kind == "superscript" and sup.content[1].text == "2", "superscript: content field")

local sc = A.statistics_cookie("[1/3]")
check(sc.kind == "statistics_cookie" and sc.value == "[1/3]", "statistics_cookie: value field")

local ts = A.timestamp("<2026-06-14 Sun>", "active")
check(
  ts.kind == "timestamp" and ts.value == "<2026-06-14 Sun>" and ts.variant == "active",
  "timestamp: value+variant"
)

local tg = A.target("x")
check(tg.kind == "target" and tg.name == "x", "target: name field")

local mac = A.macro("m", { "a", "b" })
check(mac.kind == "macro" and mac.name == "m" and mac.args[2] == "b", "macro: name+args")

local ri = A.raw_inline("@@html:<br>@@")
check(ri.kind == "raw_inline" and ri.text == "@@html:<br>@@", "raw_inline: text field")

local fn1 = A.footnote_ref("1")
check(
  fn1.kind == "footnote_ref" and fn1.label == "1" and fn1.content == nil,
  "footnote_ref: label only"
)

local fn2 = A.footnote_ref(nil, { A.text("anon") })
check(fn2.label == nil and fn2.content[1].text == "anon", "footnote_ref: anonymous content")

local mth = A.math({ display = true, body = "x", style = "dollar" })
check(
  mth.kind == "math" and mth.display == true and mth.body == "x" and mth.style == "dollar",
  "math: display+body+style"
)

-- validate accepts a document containing all the new inline kinds.
local doc = A.document({
  A.paragraph({
    A.entity("copy"),
    A.subscript({ A.text("i") }),
    A.superscript({ A.text("2") }),
    A.statistics_cookie("[1/3]"),
    A.timestamp("<2026-06-14 Sun>", "active"),
    A.target("x"),
    A.macro("m", { "a" }),
    A.raw_inline("@@html:<br>@@"),
    A.footnote_ref(nil, { A.text("anon") }),
    A.math({ display = false, body = "y", style = "dollar" }),
  }),
})
local ok, err = A.validate(doc)
check(ok, "validate: document with all new inline kinds is valid (" .. tostring(err) .. ")")

print("ALL PASS: ast_inline_nodes")
