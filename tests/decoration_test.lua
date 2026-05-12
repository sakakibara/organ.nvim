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

-- ---- attach + on_lines dispatch -------------------------------------
do
  decoration._reset()
  local on_lines_calls = {}
  decoration.register({
    name = "p1",
    ns = vim.api.nvim_create_namespace("organ_decoration_p1"),
    enabled = function(_) return true end,
    on_lines = function(bufnr, first, last_old, last_new)
      on_lines_calls[#on_lines_calls + 1] = { bufnr, first, last_old, last_new }
    end,
    on_line = function() end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line one", "line two", "line three" })

  decoration.attach(bufnr)
  -- attach should synthesize an initial on_lines covering the whole buffer.
  check(
    "attach synthesizes initial on_lines",
    #on_lines_calls == 1 and on_lines_calls[1][1] == bufnr
      and on_lines_calls[1][2] == 0 and on_lines_calls[1][4] == 3,
    "got: " .. vim.inspect(on_lines_calls)
  )

  -- Edit a line; nvim_buf_attach's on_lines fires for the edit.
  on_lines_calls = {}
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "line two (edited)" })
  vim.wait(50)
  check(
    "edit triggers on_lines dispatch",
    #on_lines_calls >= 1,
    "got " .. #on_lines_calls .. " calls"
  )

  -- attach is idempotent.
  on_lines_calls = {}
  decoration.attach(bufnr)
  check(
    "second attach is idempotent (no extra on_lines burst)",
    #on_lines_calls == 0,
    "got " .. #on_lines_calls .. " extra calls"
  )

  -- Wipe the buffer; on_detach should clear state.
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.wait(50)
  check(
    "BufWipeout clears attached state",
    decoration._attached()[bufnr] == nil,
    "still attached: " .. tostring(decoration._attached()[bufnr])
  )
end

-- ---- enabled() gate respected ---------------------------------------
do
  decoration._reset()
  local p2_calls = 0
  decoration.register({
    name = "p2",
    ns = vim.api.nvim_create_namespace("organ_decoration_p2"),
    enabled = function(_) return false end,
    on_lines = function() p2_calls = p2_calls + 1 end,
    on_line = function() end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })
  decoration.attach(bufnr)
  check("disabled provider's on_lines NOT called on attach",
    p2_calls == 0, "got " .. p2_calls .. " calls")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---- on_line dispatch ------------------------------------------------
do
  decoration._reset()
  local on_line_calls = {}
  local ns = vim.api.nvim_create_namespace("organ_decoration_p3")
  decoration.register({
    name = "p3",
    ns = ns,
    enabled = function(_) return true end,
    on_lines = function() end,
    on_line = function(bufnr, winid, row)
      on_line_calls[#on_line_calls + 1] = { bufnr, winid, row }
    end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
  decoration.attach(bufnr)

  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  decoration._dispatch_on_line(0, winid, bufnr, 0)
  decoration._dispatch_on_line(0, winid, bufnr, 1)
  check("on_line fans out to provider per row",
    #on_line_calls == 2 and on_line_calls[1][3] == 0 and on_line_calls[2][3] == 1,
    "got: " .. vim.inspect(on_line_calls))

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---- pcall isolation in on_lines ------------------------------------
do
  decoration._reset()
  local good_calls = 0
  decoration.register({
    name = "raises",
    ns = vim.api.nvim_create_namespace("organ_decoration_raises"),
    enabled = function() return true end,
    on_lines = function() error("intentional") end,
    on_line = function() end,
  })
  decoration.register({
    name = "good",
    ns = vim.api.nvim_create_namespace("organ_decoration_good"),
    enabled = function() return true end,
    on_lines = function() good_calls = good_calls + 1 end,
    on_line = function() end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })
  decoration.attach(bufnr)
  check("pcall isolates raising provider in on_lines",
    good_calls >= 1, "good_calls=" .. good_calls)
  good_calls = 0
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "y" })
  vim.wait(50)
  check("good provider keeps firing after another's failure",
    good_calls >= 1, "good_calls=" .. good_calls)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---- refresh repopulates --------------------------------------------
do
  decoration._reset()
  local call_count = 0
  decoration.register({
    name = "ref",
    ns = vim.api.nvim_create_namespace("organ_decoration_ref"),
    enabled = function() return true end,
    on_lines = function() call_count = call_count + 1 end,
    on_line = function() end,
  })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2" })
  decoration.attach(bufnr)
  call_count = 0
  decoration.refresh(bufnr)
  check("refresh triggers a fresh on_lines pass",
    call_count == 1, "got " .. call_count)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_test: PASS")
os.exit(0)
