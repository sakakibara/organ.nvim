-- Queue unit tests. Uses a fake processor so we don't touch SQLite.
-- Run via: nvim --headless -l tests/queue_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local queue = require("organ.queue")

local processed = {}
queue.init({
  process = function(path, tier, done)
    processed[#processed + 1] = { path = path, tier = tier }
    done()
  end,
})

-- FIFO + dedupe (single tier path for now; tier arg is 'interactive' default).
queue.enqueue("a.org")
queue.enqueue("b.org")
queue.enqueue("a.org") -- duplicate; should be dropped
queue.enqueue("c.org")

assert(
  vim.wait(1000, function()
    return #processed == 3
  end),
  "expected 3 processed, got " .. #processed
)

assert(processed[1].path == "a.org")
assert(processed[2].path == "b.org")
assert(processed[3].path == "c.org")

----------------------------------------------------------------------
-- Priority tiers: interactive always drains before background.

do
  local processed2 = {}
  queue.init({
    process = function(path, tier, done)
      processed2[#processed2 + 1] = { path = path, tier = tier }
      done()
    end,
  })

  queue.enqueue_background("bg1.org")
  queue.enqueue_background("bg2.org")
  queue.enqueue_interactive("ui1.org")
  queue.enqueue_background("bg3.org")
  queue.enqueue_interactive("ui2.org")

  assert(
    vim.wait(1500, function()
      return #processed2 == 5
    end),
    "expected 5 processed, got " .. #processed2
  )

  -- Only the first dequeue was already scheduled when ui1 arrived, so
  -- the first item should be bg1 (already popped), then ui1, ui2, then bg2, bg3.
  -- Lenient check: both interactive items come before both remaining background.
  local ui_idxs, bg_remaining_idxs = {}, {}
  for i, p in ipairs(processed2) do
    if p.tier == "interactive" then
      ui_idxs[#ui_idxs + 1] = i
    end
    if p.path == "bg2.org" or p.path == "bg3.org" then
      bg_remaining_idxs[#bg_remaining_idxs + 1] = i
    end
  end
  assert(
    ui_idxs[1] < bg_remaining_idxs[1],
    "interactive should preempt still-pending background; got order " .. vim.inspect(processed2)
  )
end

----------------------------------------------------------------------
-- Debounce: rapid consecutive enqueues collapse to one processing.

do
  local processed3 = {}
  queue.init({
    debounce_ms = 120,
    process = function(path, _tier, done)
      processed3[#processed3 + 1] = path
      done()
    end,
  })

  queue.enqueue_interactive("hot.org")
  queue.enqueue_interactive("hot.org")
  queue.enqueue_interactive("hot.org")
  -- Shouldn't have fired yet.
  vim.wait(50, function()
    return false
  end)
  assert(#processed3 == 0, "debounce broken: " .. #processed3)

  -- After the window, exactly one.
  assert(vim.wait(600, function()
    return #processed3 >= 1
  end))
  assert(#processed3 == 1, "expected 1, got " .. #processed3)
end

----------------------------------------------------------------------
-- Background tier: items drain one at a time, in FIFO order, via the
-- async worker contract (each calls done() when finished).

do
  local processedb = {}
  queue.init({
    process = function(item, tier, done)
      processedb[#processedb + 1] = { item = item, tier = tier }
      done()
    end,
  })

  for i = 1, 7 do
    queue.enqueue_background(string.format("f%02d.org", i))
  end

  assert(
    vim.wait(1500, function()
      return #processedb == 7
    end),
    "expected 7 processed, got " .. #processedb
  )

  for _, p in ipairs(processedb) do
    assert(p.tier == "background")
  end
  assert(processedb[1].item == "f01.org", "FIFO broken: first = " .. tostring(processedb[1].item))
  assert(processedb[7].item == "f07.org", "FIFO broken: last = " .. tostring(processedb[7].item))
end

----------------------------------------------------------------------
-- drain_blocking: waits until both tiers are empty.

do
  local processed4 = {}
  queue.init({
    process = function(p, _tier, done)
      processed4[#processed4 + 1] = p
      done()
    end,
  })
  queue.enqueue_background("x1.org")
  queue.enqueue_background("x2.org")
  queue.enqueue_interactive("x3.org")
  local ok = queue.drain_blocking(2000)
  assert(ok, "drain_blocking timed out")
  assert(#processed4 == 3, "expected 3, got " .. #processed4)
end

io.write("queue fifo+dedupe ok\n")
os.exit(0)
