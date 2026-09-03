-- organ delegates every table operation to tablature.nvim, which the
-- user installs separately, so the revision on disk is out of organ's
-- hands. Before delegating, organ checks the capability flags tablature
-- declares (`:h tablature-api-capabilities`) and refuses rather than let
-- an older copy rewrite the buffer.
--
-- Run via: nvim --headless -l tests/table_capability_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- organ.notify collapses identical messages inside a time window, which
-- would hide a missing latch; the "warned once" assertions below have to
-- be about organ.table's own state.
require("organ.notify").repeat_suppress_seconds = 0

local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end

local OPS = {
  "realign",
  "tab",
  "shift_tab",
  "insert_row_below",
  "insert_row_above",
  "delete_row",
  "move_row_up",
  "move_row_down",
  "insert_column_right",
  "insert_column_left",
  "delete_column",
  "move_column_left",
  "move_column_right",
}

local function fresh(stub)
  package.loaded["tablature"] = stub
  package.loaded["organ.table"] = nil
  package.loaded["organ.table_edit"] = nil
  notes = {}
  return require("organ.table")
end

local function mk_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "| a | b |", "| - | - |" })
  return b
end

-- The health report is a full run, so capture vim.health and reload
-- organ.health after the stub is in place.
local function health_messages()
  local msgs = {}
  vim.health = setmetatable({}, {
    __index = function(_, level)
      return function(msg)
        msgs[#msgs + 1] = { level = level, msg = tostring(msg) }
      end
    end,
  })
  package.loaded["organ.health"] = nil
  pcall(require("organ.health").check)
  local tablature_msgs = {}
  for _, m in ipairs(msgs) do
    if m.msg:match("tablature") then
      tablature_msgs[#tablature_msgs + 1] = m
    end
  end
  return tablature_msgs
end

-- ---------------------------------------------------------------------------
-- A tablature predating the capability table is too old: every operation
-- refuses, the buffer is untouched, and the user is told exactly once.

do
  local mod = fresh({})
  local buf = mk_buf()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for _, name in ipairs(OPS) do
    assert(mod[name](buf, 1) == false, name .. " should refuse")
  end
  vim.api.nvim_set_current_buf(buf)
  assert(mod.sort_by_current_column(buf, "asc") == false, "sort should refuse")
  assert(mod.eval_formulas(buf) == false, "eval_formulas should refuse")
  assert(mod._align({}, "") == nil, "_align should refuse")
  mod.open_menu()

  assert(#notes == 1, "expected exactly one notification, got " .. #notes)
  assert(notes[1].level == vim.log.levels.ERROR, "notification is an error")
  assert(notes[1].msg:match("tablature%.nvim"), "notification names tablature.nvim")
  assert(notes[1].msg:match("[Uu]pdate it"), "notification says how to fix it: " .. notes[1].msg)

  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(vim.deep_equal(before, after), "buffer must be untouched")

  local installed, missing = mod.tablature_status()
  assert(installed == true, "stub counts as installed")
  assert(#missing == 2, "both capabilities missing, got " .. #missing)

  local reported = health_messages()
  assert(#reported == 1, "health reports tablature once, got " .. #reported)
  assert(reported[1].level == "error", "health reports an error, got " .. reported[1].level)
  assert(reported[1].msg:match("older than organ needs"), "health names the cause")
  assert(reported[1].msg:match("org_table_align"), "health names the undeclared capability")

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ---------------------------------------------------------------------------
-- Declaring some but not all of the required flags is still too old.

do
  local mod = fresh({ capabilities = { org_table_align = true } })
  assert(mod.realign(mk_buf(), 1) == false, "partial capabilities should refuse")
  assert(#notes == 1, "expected one notification, got " .. #notes)
  local _, missing = mod.tablature_status()
  assert(#missing == 1 and missing[1] == "org_positional_hrule", "only the absent flag is listed")
end

-- ---------------------------------------------------------------------------
-- A tablature declaring what organ needs is delegated to in silence.

do
  local stub = {
    capabilities = { org_table_align = true, org_positional_hrule = true },
    calls = {},
  }
  for _, name in ipairs(OPS) do
    stub[name] = function()
      stub.calls[#stub.calls + 1] = name
      return true
    end
  end
  stub.align = function()
    stub.calls[#stub.calls + 1] = "align"
    return { "| a | b |" }
  end

  local mod = fresh(stub)
  local buf = mk_buf()
  for _, name in ipairs(OPS) do
    assert(mod[name](buf, 1) == true, name .. " should delegate")
  end
  assert(mod._align({}, "") ~= nil, "_align should delegate")
  assert(#stub.calls == #OPS + 1, "every operation reached tablature")
  assert(#notes == 0, "no notification when the capabilities are there")

  local installed, missing = mod.tablature_status()
  assert(installed == true and #missing == 0, "status reports a usable tablature")

  local reported = health_messages()
  assert(#reported == 1, "health reports tablature once, got " .. #reported)
  assert(reported[1].level == "ok", "health reports ok, got " .. reported[1].level)

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ---------------------------------------------------------------------------
-- No tablature at all: organ.table still loads, refuses, and says how to
-- install it.

do
  local dep = root .. "/tests/deps/tablature.nvim"
  local saved = vim.o.runtimepath
  vim.opt.runtimepath:remove(dep)

  local mod = fresh(nil)
  assert(mod.realign(mk_buf(), 1) == false, "missing tablature should refuse")
  assert(mod._parse({ "| a |" }, 1) == nil, "parse yields nothing without tablature")
  assert(#notes == 1, "expected one notification, got " .. #notes)
  assert(notes[1].msg:match("not installed"), "notification says it is missing")
  assert(notes[1].msg:match("plugin manager"), "notification says how to install it")

  local installed, missing = mod.tablature_status()
  assert(installed == false, "status reports it absent")
  assert(#missing == 2, "every capability is missing")

  local reported = health_messages()
  assert(#reported == 1, "health reports tablature once, got " .. #reported)
  assert(reported[1].msg:match("not installed"), "health says it is missing")

  vim.o.runtimepath = saved
end

io.write("table capability ok\n")
os.exit(0)
