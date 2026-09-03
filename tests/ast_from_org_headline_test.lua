-- from_org headline parsing: TODO keywords from #+TODO / #+SEQ_TODO /
-- #+TYP_TODO lines (fast-access keys stripped, every line accumulates)
-- and the tag character set (org-tag-re: alnum, _, @, #, %).
-- Run via: nvim --headless -l tests/ast_from_org_headline_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local from_org = require("organ.ast.from_org")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function title_text(h)
  local t = {}
  for _, n in ipairs(h.title or {}) do
    t[#t + 1] = n.text or ("<" .. n.kind .. ">")
  end
  return table.concat(t)
end

local function headlines(lines)
  local out = {}
  for _, c in ipairs(from_org.from_lines(lines).children) do
    if c.kind == "headline" then
      out[#out + 1] = c
    end
  end
  return out
end

-- Fast-access keys: `TODO(t)` defines the keyword `TODO`.
do
  local hs = headlines({ "#+TODO: TODO(t) | DONE(d)", "* TODO write tests", "* DONE ship" })
  check("fast key: TODO recognised", hs[1].todo == "TODO", "got " .. tostring(hs[1].todo))
  check("fast key: title stripped", title_text(hs[1]) == "write tests", title_text(hs[1]))
  check("fast key: DONE recognised", hs[2].todo == "DONE", "got " .. tostring(hs[2].todo))
end

-- Keywords containing `-` (a Lua pattern quantifier when unescaped).
do
  local hs = headlines({ "#+TODO: TODO IN-PROGRESS | DONE", "* IN-PROGRESS refactor" })
  check("dash keyword recognised", hs[1].todo == "IN-PROGRESS", "got " .. tostring(hs[1].todo))
  check("dash keyword stripped from title", title_text(hs[1]) == "refactor", title_text(hs[1]))
end

-- Several #+TODO / #+SEQ_TODO / #+TYP_TODO lines accumulate.
do
  local hs = headlines({
    "#+TODO: TODO | DONE",
    "#+SEQ_TODO: REPORT BUG | FIXED",
    "#+TYP_TODO: Fred Sara | DONE",
    "* TODO a",
    "* BUG b",
    "* Sara c",
  })
  check("first #+TODO line kept", hs[1].todo == "TODO", "got " .. tostring(hs[1].todo))
  check("#+SEQ_TODO line kept", hs[2].todo == "BUG", "got " .. tostring(hs[2].todo))
  check("#+TYP_TODO line kept", hs[3].todo == "Sara", "got " .. tostring(hs[3].todo))
end

-- A keyword that is a prefix of a word in the title does not match.
do
  local hs = headlines({ "#+TODO: TODO | DONE", "* TODOS are not keywords" })
  check("prefix does not match", hs[1].todo == nil, "got " .. tostring(hs[1].todo))
end

-- Tags may contain `#`, `%`, `@`, `_` and non-ASCII letters.
do
  local hs = headlines({
    "* Head :c#:",
    "* Two :\230\151\165\230\156\172\232\170\158:",
    "* Three :a%b:",
    "* Four :ok_tag@x:",
  })
  check("tag with #", hs[1].tags and hs[1].tags[1] == "c#", vim.inspect(hs[1].tags))
  check("title without # tag", title_text(hs[1]) == "Head", title_text(hs[1]))
  check(
    "non-ASCII tag",
    hs[2].tags and hs[2].tags[1] == "\230\151\165\230\156\172\232\170\158",
    vim.inspect(hs[2].tags)
  )
  check("tag with %", hs[3].tags and hs[3].tags[1] == "a%b", vim.inspect(hs[3].tags))
  check("tag with _ and @", hs[4].tags and hs[4].tags[1] == "ok_tag@x", vim.inspect(hs[4].tags))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_from_org_headline_test: PASS")
os.exit(0)
