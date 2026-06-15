-- list_item carries marker/counter/checkbox/tag; validate recurses tag.
-- Run via: nvim --headless -l tests/ast_list_nodes_test.lua
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

local li = A.list_item({
  marker = "1)",
  counter = "5",
  checkbox = "done",
  tag = { A.text("term") },
  content = { A.paragraph({ A.text("body") }) },
})
check(li.kind == "list_item", "list_item: kind")
check(li.marker == "1)", "list_item: marker field")
check(li.counter == "5", "list_item: counter field")
check(li.checkbox == "done", "list_item: checkbox field")
check(li.tag[1].text == "term", "list_item: tag inline field")
check(li.content[1].kind == "paragraph", "list_item: content field")

-- Back-compat: omitting the new fields yields nil (not error).
local bare = A.list_item({ content = {} })
check(
  bare.marker == nil and bare.counter == nil and bare.tag == nil,
  "list_item: new fields optional"
)

-- validate recurses into tag inline nodes.
local doc = A.document({
  A.list(false, {
    A.list_item({ marker = "-", tag = { A.text("t") }, content = { A.paragraph({ A.text("d") }) } }),
  }),
})
local ok, err = A.validate(doc)
check(ok, "validate: list_item with tag is valid (" .. tostring(err) .. ")")

print("ALL PASS: ast_list_nodes")
