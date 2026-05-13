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
    enabled = function()
      return true
    end,
    on_win = function() end,
    on_line = function() end,
  })
  check("register accepts a valid provider", ok, err)

  -- Duplicate name should error.
  local ok2, err2 = pcall(decoration.register, {
    name = "test_a",
    ns = ns,
    enabled = function()
      return true
    end,
    on_win = function() end,
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
    on_win = function() end,
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
    enabled = function()
      return true
    end,
    on_win = function() end,
    on_line = function() end,
  })
  decoration.unregister("test_c")
  -- Should be able to register again with same name now.
  local ok, err = pcall(decoration.register, {
    name = "test_c",
    ns = vim.api.nvim_create_namespace("organ_decoration_test_c2"),
    enabled = function()
      return true
    end,
    on_win = function() end,
    on_line = function() end,
  })
  check("unregister frees the name for re-registration", ok, err)
end

-- ---- attach + on_lines_only dispatch --------------------------------
do
  decoration._reset()
  local on_lines_calls = {}
  decoration.register({
    name = "p1",
    ns = vim.api.nvim_create_namespace("organ_decoration_p1"),
    enabled = function(_)
      return true
    end,
    on_lines_only = function(bufnr, first, last_old, last_new)
      on_lines_calls[#on_lines_calls + 1] = { bufnr, first, last_old, last_new }
    end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line one", "line two", "line three" })

  decoration.attach(bufnr)
  -- attach should synthesize an initial on_lines covering the whole buffer.
  check(
    "attach synthesizes initial on_lines_only",
    #on_lines_calls == 1
      and on_lines_calls[1][1] == bufnr
      and on_lines_calls[1][2] == 0
      and on_lines_calls[1][4] == 3,
    "got: " .. vim.inspect(on_lines_calls)
  )

  -- Edit a line; nvim_buf_attach's on_lines fires for the edit.
  on_lines_calls = {}
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "line two (edited)" })
  vim.wait(50)
  check(
    "edit triggers on_lines_only dispatch",
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
    enabled = function(_)
      return false
    end,
    on_lines_only = function()
      p2_calls = p2_calls + 1
    end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })
  decoration.attach(bufnr)
  check(
    "disabled provider's on_lines_only NOT called on attach",
    p2_calls == 0,
    "got " .. p2_calls .. " calls"
  )
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
    enabled = function(_)
      return true
    end,
    on_win = function() end,
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
  check(
    "on_line fans out to provider per row",
    #on_line_calls == 2 and on_line_calls[1][3] == 0 and on_line_calls[2][3] == 1,
    "got: " .. vim.inspect(on_line_calls)
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---- pcall isolation in on_lines_only -------------------------------
do
  decoration._reset()
  local good_calls = 0
  decoration.register({
    name = "raises",
    ns = vim.api.nvim_create_namespace("organ_decoration_raises"),
    enabled = function()
      return true
    end,
    on_lines_only = function()
      error("intentional")
    end,
  })
  decoration.register({
    name = "good",
    ns = vim.api.nvim_create_namespace("organ_decoration_good"),
    enabled = function()
      return true
    end,
    on_lines_only = function()
      good_calls = good_calls + 1
    end,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })
  decoration.attach(bufnr)
  check(
    "pcall isolates raising provider in on_lines_only",
    good_calls >= 1,
    "good_calls=" .. good_calls
  )
  good_calls = 0
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "y" })
  vim.wait(50)
  check(
    "good provider keeps firing after another's failure",
    good_calls >= 1,
    "good_calls=" .. good_calls
  )
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ---- refresh repopulates --------------------------------------------
do
  decoration._reset()
  local call_count = 0
  decoration.register({
    name = "ref",
    ns = vim.api.nvim_create_namespace("organ_decoration_ref"),
    enabled = function()
      return true
    end,
    on_lines_only = function()
      call_count = call_count + 1
    end,
  })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2" })
  decoration.attach(bufnr)
  call_count = 0
  decoration.refresh(bufnr)
  check("refresh triggers a fresh on_lines_only pass", call_count == 1, "got " .. call_count)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- on_win registration: accepted as an alternative-or-addition to on_lines.
do
  decoration._reset()
  local ns = vim.api.nvim_create_namespace("test_on_win_register")
  decoration.register({
    name = "p_on_win",
    ns = ns,
    enabled = function()
      return true
    end,
    on_win = function() end,
    on_line = function() end,
  })
  local providers = decoration._providers()
  check(
    "register accepts on_win + on_line",
    providers.p_on_win ~= nil
      and type(providers.p_on_win.on_win) == "function"
      and type(providers.p_on_win.on_line) == "function"
  )
end

-- on_lines (without on_lines_only) is no longer supported.
do
  decoration._reset()
  local ns = vim.api.nvim_create_namespace("test_on_lines_rejected")
  local ok, err = pcall(decoration.register, {
    name = "p_on_lines_only_field",
    ns = ns,
    enabled = function()
      return true
    end,
    on_lines = function() end,
    on_line = function() end,
  })
  check("on_lines (non-only) is no longer accepted", not ok and err and err:match("on_lines"))
end

-- on_win without on_line is rejected.
do
  decoration._reset()
  local ns = vim.api.nvim_create_namespace("test_on_win_no_on_line")
  local ok, err = pcall(decoration.register, {
    name = "p_on_win_only",
    ns = ns,
    enabled = function()
      return true
    end,
    on_win = function() end,
  })
  check("on_win without on_line is rejected", not ok and err and err:match("on_line"))
end

-- on_win fires before on_line in the dispatch order, both with pcall.
do
  decoration._reset()
  local ns = vim.api.nvim_create_namespace("test_on_win_dispatch_order")
  local events = {}
  decoration.register({
    name = "p_order",
    ns = ns,
    enabled = function()
      return true
    end,
    on_win = function(_, _, topline, botline)
      events[#events + 1] = { "on_win", topline, botline }
    end,
    on_line = function(_, _, row)
      events[#events + 1] = { "on_line", row }
    end,
  })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
  decoration.attach(bufnr)
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  decoration._dispatch_on_win(0, winid, bufnr, 0, 3)
  decoration._dispatch_on_line(0, winid, bufnr, 0)
  decoration._dispatch_on_line(0, winid, bufnr, 1)
  decoration._dispatch_on_line(0, winid, bufnr, 2)
  check(
    "on_win called once with [topline, botline]",
    events[1] and events[1][1] == "on_win" and events[1][2] == 0 and events[1][3] == 3
  )
  check(
    "on_line called for each visible row after on_win",
    events[2]
      and events[2][1] == "on_line"
      and events[2][2] == 0
      and events[3]
      and events[3][1] == "on_line"
      and events[3][2] == 1
      and events[4]
      and events[4][1] == "on_line"
      and events[4][2] == 2
  )
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- on_win provider that raises is disabled after one failure and
-- skipped on subsequent dispatches.
do
  decoration._reset()
  local ns = vim.api.nvim_create_namespace("test_on_win_disable_on_error")
  local call_count = 0
  decoration.register({
    name = "p_raises_on_win",
    ns = ns,
    enabled = function()
      return true
    end,
    on_win = function()
      call_count = call_count + 1
      error("intentional on_win error")
    end,
    on_line = function() end,
  })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a" })
  decoration.attach(bufnr)
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  decoration._dispatch_on_win(0, winid, bufnr, 0, 1)
  decoration._dispatch_on_win(0, winid, bufnr, 0, 1)
  decoration._dispatch_on_win(0, winid, bufnr, 0, 1)
  -- New semantics: raising providers are NOT permanently disabled.  A
  -- transient error (stale tree-sitter injection, etc.) shouldn't lock
  -- a provider off until reload.  The dispatcher pcalls each invocation
  -- and surfaces ONE warning via notify; subsequent redraws keep
  -- retrying, so a recovered state restores the provider automatically.
  check(
    "raising on_win provider keeps being retried after error",
    call_count == 3,
    "called " .. call_count .. " times (expected 3)"
  )
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
