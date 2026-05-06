-- Unit tests for lua/organ/events.lua.
-- Run via: nvim --headless -l tests/events_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local events = require("organ.events")

----------------------------------------------------------------------
-- on / emit round-trip.
do
  events.clear()
  local got = {}
  events.on("x", function(p)
    got[#got + 1] = p
  end)
  events.emit("x", { value = 1 })
  events.emit("x", { value = 2 })
  assert(#got == 2, "expected 2 payloads, got " .. #got)
  assert(got[1].value == 1 and got[2].value == 2)
end

----------------------------------------------------------------------
-- Multiple listeners on the same event.
do
  events.clear()
  local a, b = 0, 0
  events.on("x", function()
    a = a + 1
  end)
  events.on("x", function()
    b = b + 1
  end)
  events.emit("x")
  assert(a == 1 and b == 1, "both listeners should fire")
end

----------------------------------------------------------------------
-- off() removes a specific listener.
do
  events.clear()
  local a, b = 0, 0
  local fn_a = function()
    a = a + 1
  end
  events.on("x", fn_a)
  events.on("x", function()
    b = b + 1
  end)
  events.off("x", fn_a)
  events.emit("x")
  assert(a == 0 and b == 1, "off should only remove fn_a")
end

----------------------------------------------------------------------
-- pcall isolation: a raising listener doesn't kill others.
do
  events.clear()
  local reached = false
  events.on("x", function()
    error("boom")
  end)
  events.on("x", function()
    reached = true
  end)
  events.emit("x") -- must not raise
  assert(reached, "second listener should still fire despite first raising")
end

----------------------------------------------------------------------
-- clear() empties all listeners by default; clear(event) empties one.
do
  events.clear()
  local a, b = 0, 0
  events.on("x", function()
    a = a + 1
  end)
  events.on("y", function()
    b = b + 1
  end)
  events.clear("x")
  events.emit("x")
  events.emit("y")
  assert(a == 0 and b == 1)
  events.clear()
  events.emit("y")
  assert(b == 1) -- no additional increment
end

----------------------------------------------------------------------
-- emit on unknown event is a no-op (not an error).
do
  events.clear()
  events.emit("nonexistent", { any = "payload" }) -- must not raise
end

----------------------------------------------------------------------
-- Integration: indexer emits "indexed" on successful write.
do
  events.clear()
  local payloads = {}
  events.on("indexed", function(p)
    payloads[#payloads + 1] = p
  end)

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local db_path = tmp .. "/e.db"
  local org_dir = tmp .. "/org"
  vim.fn.mkdir(org_dir, "p")
  vim.fn.system({ "cp", root .. "/tests/fixtures/01-headlines.org", org_dir .. "/01.org" })

  require("organ").setup({
    db_path = db_path,
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })

  -- Clear after setup so we get a clean slate for the explicit enqueue below.
  payloads = {}

  require("organ.queue").enqueue_interactive(org_dir .. "/01.org")
  assert(require("organ.queue").drain_blocking(5000))

  local found
  for _, p in ipairs(payloads) do
    if p.path == org_dir .. "/01.org" and p.n_headlines == 7 then
      found = true
      break
    end
  end
  assert(found, "indexed event not fired with expected payload; got: " .. vim.inspect(payloads))

  vim.fn.delete(tmp, "rf")
end

----------------------------------------------------------------------
-- Integration: scan_done fires with n_ok count.
do
  events.clear()
  local done_payload
  events.on("scan_done", function(p)
    done_payload = p
  end)

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local db_path = tmp .. "/e2.db"
  local org_dir = tmp .. "/org"
  vim.fn.mkdir(org_dir, "p")
  for _, name in ipairs({ "01-headlines.org", "02-planning.org", "03-properties.org" }) do
    vim.fn.system({ "cp", root .. "/tests/fixtures/" .. name, org_dir .. "/" .. name })
  end

  require("organ").setup({
    db_path = db_path,
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })
  events.clear()
  events.on("scan_done", function(p)
    done_payload = p
  end)

  require("organ").scan_blocking(org_dir, 5000)
  assert(done_payload, "scan_done not fired")
  assert(done_payload.n_ok == 3, "n_ok = " .. tostring(done_payload.n_ok))
  assert(type(done_payload.errors) == "table")

  vim.fn.delete(tmp, "rf")
end

----------------------------------------------------------------------
-- Back-compat: user's on_index / on_scan_done callbacks still fire.
do
  events.clear()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local db_path = tmp .. "/e3.db"
  local org_dir = tmp .. "/org"
  vim.fn.mkdir(org_dir, "p")
  vim.fn.system({ "cp", root .. "/tests/fixtures/01-headlines.org", org_dir .. "/01.org" })

  local n_index_calls = 0
  local scan_done_n_ok
  require("organ").setup({
    db_path = db_path,
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    on_index = function(_path, n)
      n_index_calls = n_index_calls + 1
    end,
    on_scan_done = function(n_ok, _errs)
      scan_done_n_ok = n_ok
    end,
  })

  require("organ.queue").enqueue_interactive(org_dir .. "/01.org")
  assert(require("organ.queue").drain_blocking(5000))
  assert(n_index_calls >= 1, "on_index should have fired")

  require("organ").scan_blocking(org_dir, 5000)
  assert(scan_done_n_ok == 1, "on_scan_done n_ok = " .. tostring(scan_done_n_ok))

  vim.fn.delete(tmp, "rf")
end

----------------------------------------------------------------------
-- Back-compat: on_index fires with n=0 for skipped files.
do
  events.clear()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local db_path = tmp .. "/e4.db"
  local org_dir = tmp .. "/org"
  vim.fn.mkdir(org_dir, "p")
  vim.fn.system({ "cp", root .. "/tests/fixtures/01-headlines.org", org_dir .. "/01.org" })

  local calls = {}
  require("organ").setup({
    db_path = db_path,
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    on_index = function(path, n)
      table.insert(calls, { path = path, n = n })
    end,
  })

  -- First index: write happens → n should be 7 (fixture 01 has 7 headlines).
  require("organ.queue").enqueue_interactive(org_dir .. "/01.org")
  assert(require("organ.queue").drain_blocking(5000))

  -- Second index of the same unchanged file: hash or mtime skip → n should be 0.
  require("organ.queue").enqueue_interactive(org_dir .. "/01.org")
  assert(require("organ.queue").drain_blocking(5000))

  local last = calls[#calls]
  assert(
    last and last.n == 0,
    "last on_index call should be n=0 (skipped); got: " .. vim.inspect(calls)
  )

  vim.fn.delete(tmp, "rf")
end

----------------------------------------------------------------------
-- Back-compat: calling setup() twice doesn't duplicate listeners.
do
  events.clear()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local db_path = tmp .. "/e5.db"
  local org_dir = tmp .. "/org"
  vim.fn.mkdir(org_dir, "p")
  vim.fn.system({ "cp", root .. "/tests/fixtures/01-headlines.org", org_dir .. "/01.org" })

  local n = 0
  local cb = function()
    n = n + 1
  end

  require("organ").setup({
    db_path = db_path,
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    on_index = cb,
  })
  -- Simulate a plugin-manager re-run.
  require("organ").setup({
    db_path = db_path,
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    on_index = cb,
  })

  require("organ.queue").enqueue_interactive(org_dir .. "/01.org")
  assert(require("organ.queue").drain_blocking(5000))

  assert(
    n == 1,
    "on_index should fire exactly once per file even after two setup() calls; got " .. n
  )

  vim.fn.delete(tmp, "rf")
end

io.write("events ok\n")
os.exit(0)
