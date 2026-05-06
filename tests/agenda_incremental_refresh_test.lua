-- Regression test for the agenda flicker bug.
--
-- Before fix: M.refresh() always called nvim_buf_set_lines(0, -1, ...)
-- replacing the WHOLE buffer on every keypress, even when only one line
-- changed. That caused visible flicker on `t` (TODO cycle).
--
-- After fix: refresh diffs old vs new lines. If identical → skip the write
-- entirely (no undo step, no flicker). If a single line changed → only
-- replace that line range. Only a row count change triggers a full replace.
--
-- We assert by patching nvim_buf_set_lines to count its calls and ranges.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Stub the query layer so we can return controlled rows
local current_rows = {
  {
    id = "h1",
    file_path = "/tmp/a.org",
    title = "Headline one",
    line_start = 0,
    level = 1,
    todo_state = "TODO",
  },
  {
    id = "h2",
    file_path = "/tmp/a.org",
    title = "Headline two",
    line_start = 4,
    level = 1,
    todo_state = "DONE",
  },
}
package.loaded["organ.query"] = {
  agenda = function()
    return current_rows
  end,
  headlines = function()
    return current_rows
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  agenda = {
    views = {
      test = {
        blocks = {
          {
            source = "headlines",
            title = "Test block",
            line_format = "{title} [{todo_state}]",
          },
        },
      },
    },
  },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

local agenda = require("organ.agenda")

-- Open the agenda buffer (simulates user running :Org agenda test)
agenda.open({ name = "test" })
local bufnr = vim.api.nvim_get_current_buf()

-- Patch nvim_buf_set_lines AND nvim_buf_clear_namespace AND
-- nvim_buf_set_extmark to count + record ranges. Both LINE writes
-- AND extmark writes contribute to flicker; both must be incremental.
local set_lines_calls = {}
local clear_ns_calls = {}
local set_extmark_calls = {}
local original_set_lines = vim.api.nvim_buf_set_lines
local original_clear_ns = vim.api.nvim_buf_clear_namespace
local original_set_extmark = vim.api.nvim_buf_set_extmark
vim.api.nvim_buf_set_lines = function(buf, start, stop, strict, lines)
  if buf == bufnr or buf == 0 then
    table.insert(set_lines_calls, { start = start, stop = stop, n_lines = #lines })
  end
  return original_set_lines(buf, start, stop, strict, lines)
end
vim.api.nvim_buf_clear_namespace = function(buf, ns, start, stop)
  if buf == bufnr or buf == 0 then
    table.insert(clear_ns_calls, { ns = ns, start = start, stop = stop })
  end
  return original_clear_ns(buf, ns, start, stop)
end
vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
  if buf == bufnr or buf == 0 then
    table.insert(set_extmark_calls, { row = row, col = col })
  end
  return original_set_extmark(buf, ns, row, col, opts)
end
local function reset_logs()
  set_lines_calls = {}
  clear_ns_calls = {}
  set_extmark_calls = {}
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Test 1: refresh with NO changes → zero buf_set_lines AND zero extmark touches
reset_logs()
agenda.refresh(bufnr)
check(
  "identical refresh: zero buf_set_lines calls",
  #set_lines_calls == 0,
  "got " .. #set_lines_calls .. " calls"
)
check(
  "identical refresh: zero clear_namespace calls (no extmark flicker)",
  #clear_ns_calls == 0,
  "got " .. #clear_ns_calls .. " calls"
)
check(
  "identical refresh: zero set_extmark calls",
  #set_extmark_calls == 0,
  "got " .. #set_extmark_calls .. " calls"
)

-- Test 2: refresh after toggling one TODO state → only changed range touched,
-- AND extmark namespace is only cleared in that range (not full buffer)
current_rows[1].todo_state = "DONE"
reset_logs()
agenda.refresh(bufnr)
check(
  "one TODO change: at most one buf_set_lines call",
  #set_lines_calls == 1,
  "got " .. #set_lines_calls .. " calls"
)
if #set_lines_calls == 1 then
  local call = set_lines_calls[1]
  local range_size = call.stop - call.start
  check(
    "one TODO change: line range covers only changed lines",
    range_size <= 5,
    "range = " .. call.start .. ".." .. call.stop
  )
end
check(
  "one TODO change: clear_namespace called with NARROW range, not 0..-1",
  #clear_ns_calls == 1 and clear_ns_calls[1].start ~= 0
    or (clear_ns_calls[1] and clear_ns_calls[1].stop ~= -1),
  "calls=" .. vim.inspect(clear_ns_calls)
)
if #clear_ns_calls >= 1 and clear_ns_calls[1].stop and clear_ns_calls[1].stop ~= -1 then
  local clear = clear_ns_calls[1]
  local range_size = clear.stop - clear.start
  check(
    "one TODO change: extmark clear range matches changed lines (small)",
    range_size <= 5,
    "clear range = " .. clear.start .. ".." .. clear.stop
  )
end

-- Test 3: refresh after adding a row → full replace path is taken (line count differs)
table.insert(current_rows, {
  id = "h3",
  file_path = "/tmp/a.org",
  title = "Headline three",
  line_start = 8,
  level = 1,
  todo_state = "TODO",
})
reset_logs()
agenda.refresh(bufnr)
check(
  "row added: buf_set_lines was called (full replace acceptable here)",
  #set_lines_calls >= 1,
  "got " .. #set_lines_calls .. " calls"
)

vim.api.nvim_buf_set_lines = original_set_lines

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_incremental_refresh_test: PASS")
