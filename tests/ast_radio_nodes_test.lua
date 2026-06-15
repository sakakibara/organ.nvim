-- radio_target constructor + validate; link accepts form="radio".
-- Run via: nvim --headless -l tests/ast_radio_nodes_test.lua
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

local rt = A.radio_target("my phrase")
check(rt.kind == "radio_target" and rt.phrase == "my phrase", "radio_target: phrase field")

local lk = A.link("my phrase", { A.text("My Phrase") }, "radio")
check(lk.kind == "link" and lk.form == "radio" and lk.target == "my phrase", "link: radio form")

local doc = A.document({ A.paragraph({ A.radio_target("p"), A.text(" x "), lk }) })
local ok, err = A.validate(doc)
check(ok, "validate: doc with radio_target + radio link is valid (" .. tostring(err) .. ")")

print("ALL PASS: ast_radio_nodes")
