-- enqueue_background_op accepts {kind, path}; process_batch receives op records
-- alongside legacy string paths.
-- Run via: nvim --headless -l tests/queue_op_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local queue = require("organ.queue")

local got = {}
queue.init({
  debounce_ms = 0,
  scan_batch_size = 10,
  process_batch = function(items, _tier)
    for _, it in ipairs(items) do
      got[#got + 1] = it
    end
  end,
})

queue.enqueue_background("/a.org") -- legacy string path
queue.enqueue_background_op({ kind = "delete", path = "/b.org" })
queue.enqueue_background_op({ kind = "index", path = "/c.org" })

vim.wait(300, function()
  return #got >= 3
end, 10)

assert(#got == 3, "got " .. #got)
-- First item: legacy string path normalised by queue/process_batch consumer.
-- Spec: process_batch sees either strings or {kind, path}; both shapes are
-- valid and the consumer (init.lua) normalises.
local function as_op(it)
  if type(it) == "string" then
    return { kind = "index", path = it }
  end
  return it
end
local ops = { as_op(got[1]), as_op(got[2]), as_op(got[3]) }
assert(ops[1].kind == "index" and ops[1].path == "/a.org", "got[1]=" .. vim.inspect(ops[1]))
assert(ops[2].kind == "delete" and ops[2].path == "/b.org", "got[2]=" .. vim.inspect(ops[2]))
assert(ops[3].kind == "index" and ops[3].path == "/c.org", "got[3]=" .. vim.inspect(ops[3]))

io.write("queue op ok\n")
os.exit(0)
