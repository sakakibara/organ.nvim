-- Unit tests for organ.decoration shared infrastructure.
--
-- Run via: nvim --headless -l tests/decoration_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- ---- register API ----------------------------------------------------
do
  -- Reset state between tests via _reset (internal helper for tests).
  decoration._reset()

  local ns = vim.api.nvim_create_namespace("organ_decoration_test_a")
  local ok, err = pcall(decoration.register, {
    name = "test_a",
    ns = ns,
    enabled = function() return true end,
    on_lines = function() end,
    on_line = function() end,
  })
  check("register accepts a valid provider", ok, err)

  -- Duplicate name should error.
  local ok2, err2 = pcall(decoration.register, {
    name = "test_a",
    ns = ns,
    enabled = function() return true end,
    on_lines = function() end,
    on_line = function() end,
  })
  check(
    "register rejects duplicate names",
    not ok2 and type(err2) == "string" and err2:find("already registered", 1, true) ~= nil,
    "got: ok=" .. tostring(ok2) .. " err=" .. tostring(err2)
  )

  -- Missing required field should error.
  local ok3, err3 = pcall(decoration.register, {
    name = "test_b",
    ns = vim.api.nvim_create_namespace("organ_decoration_test_b"),
    -- enabled missing
    on_lines = function() end,
    on_line = function() end,
  })
  check(
    "register rejects missing required fields",
    not ok3 and type(err3) == "string" and err3:find("missing field", 1, true) ~= nil,
    "got: ok=" .. tostring(ok3) .. " err=" .. tostring(err3)
  )
end

-- ---- unregister ------------------------------------------------------
do
  decoration._reset()
  decoration.register({
    name = "test_c",
    ns = vim.api.nvim_create_namespace("organ_decoration_test_c"),
    enabled = function() return true end,
    on_lines = function() end,
    on_line = function() end,
  })
  decoration.unregister("test_c")
  -- Should be able to register again with same name now.
  local ok, err = pcall(decoration.register, {
    name = "test_c",
    ns = vim.api.nvim_create_namespace("organ_decoration_test_c2"),
    enabled = function() return true end,
    on_lines = function() end,
    on_line = function() end,
  })
  check("unregister frees the name for re-registration", ok, err)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_test: PASS")
os.exit(0)
