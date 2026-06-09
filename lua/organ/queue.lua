-- Single-consumer two-tier write queue. Interactive tier preempts background.

local M = {}
local state
-- Pre-init buffer: enqueues that arrive before `setup() → init()`
-- accumulate here.  init() drains them into the real state.  The
-- buffer is intentionally NOT processed (no `process` callback) —
-- items wait until init() wires the real callback.
--
-- Common triggers for pre-init enqueues:
--   * lazy.nvim loading organ.nvim on FileType=org → an autocmd
--     fires before setup() finishes
--   * `:Lazy reload organ.nvim` → reloaded module's `state` is nil
--     while a watcher fs_event from the previous instance still
--     holds a reference and fires
--   * any third-party plugin that requires organ.queue and enqueues
--     before the user's organ.setup() runs
local _pre_init = { interactive = {}, background = {} }

local function new_state(opts)
  return {
    interactive = { q = {}, seen = {} },
    background = { q = {}, seen = {} },
    process = opts.process or function() end,
    process_batch = opts.process_batch, -- optional; if set, used for background drains
    debounce_ms = opts.debounce_ms or 0,
    scan_batch_size = opts.scan_batch_size or 50, -- max files per background tick
    scan_budget_ms = opts.scan_budget_ms or 10, -- target wall time per background tick
    bg_batch = 1, -- adaptive batch size, converges so a tick costs ~scan_budget_ms
    row_chunk = opts.row_chunk or 10000,
    pending = {},
    running = false,
  }
end

function M.init(opts)
  -- Stop any debounce timers from the previous state before
  -- replacing it; otherwise stale timers will fire their callbacks
  -- into the new state.
  if state then
    for _, t in pairs(state.pending) do
      pcall(function()
        t:stop()
        t:close()
      end)
    end
  end
  state = new_state(opts)
  -- Adopt any pre-init buffered items, then clear the buffer so a
  -- subsequent `init()` (e.g. plugin reload) doesn't re-enqueue
  -- already-processed paths.
  local pre = _pre_init
  _pre_init = { interactive = {}, background = {} }
  for _, p in ipairs(pre.interactive) do
    M.enqueue_interactive(p)
  end
  for _, p in ipairs(pre.background) do
    M.enqueue_background(p)
  end
end

local function step()
  if not state or state.running then
    return
  end

  -- Interactive tier: one-at-a-time (low latency).
  if #state.interactive.q > 0 then
    local path = table.remove(state.interactive.q, 1)
    state.interactive.seen[path] = nil
    state.running = true
    local ok, err = pcall(state.process, path, "interactive")
    state.running = false
    if not ok then
      vim.schedule(function()
        require("organ.notify").error("queue: worker error: " .. tostring(err))
      end)
    end
  -- Background tier: adaptive batch sized to the per-tick time budget.
  -- A fixed count freezes the UI proportional to file size (10 large
  -- files in one synchronous transaction = a multi-hundred-ms block on
  -- startup); sizing by observed per-item cost keeps each tick near
  -- scan_budget_ms regardless of file size, yielding between ticks.
  elseif #state.background.q > 0 then
    local n = math.min(state.bg_batch, #state.background.q)
    local batch = {}
    for _ = 1, n do
      local p = table.remove(state.background.q, 1)
      local key = (type(p) == "string" and ("index\0" .. p)) or (p.kind .. "\0" .. p.path)
      state.background.seen[key] = nil
      batch[#batch + 1] = p
    end
    state.running = true
    local t0 = vim.uv.hrtime()
    local ok, err
    if state.process_batch then
      ok, err = pcall(state.process_batch, batch, "background")
    else
      for _, p in ipairs(batch) do
        ok, err = pcall(state.process, p, "background")
        if not ok then
          break
        end
      end
    end
    state.running = false
    local dt_ms = (vim.uv.hrtime() - t0) / 1e6
    if dt_ms > 0 then
      local per_item = dt_ms / n
      state.bg_batch =
        math.max(1, math.min(state.scan_batch_size, math.floor(state.scan_budget_ms / per_item)))
    end
    if not ok then
      vim.schedule(function()
        require("organ.notify").error("queue: worker error: " .. tostring(err))
      end)
    end
  end

  if #state.interactive.q > 0 or #state.background.q > 0 then
    vim.schedule(step)
  end
end

-- Seen-set key for a plain string path (always treated as an "index" op).
-- Op records use (kind .. "\0" .. path) directly.
local function bg_key_for_path(path)
  return "index\0" .. path
end

local function push_now(tier_name, path)
  local tier = state[tier_name]
  -- Interactive tier uses the plain path as seen key (unchanged behaviour).
  -- Background tier uses the unified "kind\0path" scheme so string paths and
  -- op records share the same key space without collisions.
  local seen_key = (tier_name == "background") and bg_key_for_path(path) or path
  if tier.seen[seen_key] then
    return false
  end
  if tier_name == "interactive" then
    local bg_key = bg_key_for_path(path)
    if state.background.seen[bg_key] then
      for i, p in ipairs(state.background.q) do
        if p == path then
          table.remove(state.background.q, i)
          break
        end
      end
      state.background.seen[bg_key] = nil
    end
  end
  tier.q[#tier.q + 1] = path
  tier.seen[seen_key] = true
  vim.schedule(step)
  return true
end

local function enq(tier_name, path)
  if not state then
    -- Pre-init: buffer the path until setup()'s init() drains us.
    -- Dedupe within the buffer so a flood of events (watcher tick
    -- repeating during a slow plugin load) doesn't snowball.
    local buf = _pre_init[tier_name]
    if buf then
      for _, existing in ipairs(buf) do
        if existing == path then
          return true
        end
      end
      buf[#buf + 1] = path
    end
    return true
  end
  -- Only the interactive tier is debounced.
  if tier_name == "interactive" and state.debounce_ms > 0 then
    if state.pending[path] then
      pcall(function()
        state.pending[path]:stop()
        state.pending[path]:close()
      end)
    end
    local t = vim.loop.new_timer()
    state.pending[path] = t
    t:start(
      state.debounce_ms,
      0,
      vim.schedule_wrap(function()
        -- Defensive: same path may have been re-debounced + cancelled between
        -- start and fire. Skip cleanly when already closed.
        if t:is_closing() then
          return
        end
        t:stop()
        t:close()
        if state.pending[path] == t then
          state.pending[path] = nil
        end
        push_now("interactive", path)
      end)
    )
    return true
  end
  return push_now(tier_name, path)
end

function M.enqueue_interactive(path)
  return enq("interactive", path)
end
function M.enqueue_background(path)
  return enq("background", path)
end

-- Op records: {kind = "index"|"delete", path = string}.
-- Dedupe key is (kind .. "\0" .. path) so an index and a delete for the same
-- path don't shadow each other in the seen-set.
function M.enqueue_background_op(op)
  if not state then
    error("organ.queue not initialised; call queue.init first")
  end
  if
    type(op) ~= "table"
    or type(op.path) ~= "string"
    or (op.kind ~= "index" and op.kind ~= "delete")
  then
    error("enqueue_background_op: op must be {kind='index'|'delete', path=string}")
  end
  local tier = state.background
  local key = op.kind .. "\0" .. op.path
  if tier.seen[key] then
    return false
  end
  tier.q[#tier.q + 1] = op
  tier.seen[key] = true
  vim.schedule(step)
  return true
end

-- Back-compat alias used in task 9 test: enqueue -> enqueue_interactive.
function M.enqueue(path)
  return M.enqueue_interactive(path)
end

function M.is_empty()
  if state == nil then
    return true
  end
  if next(state.pending) ~= nil then
    return false
  end
  return #state.interactive.q == 0 and #state.background.q == 0 and not state.running
end

function M.depth()
  if not state then
    return 0, 0
  end
  return #state.interactive.q, #state.background.q
end

function M.row_chunk()
  return state and state.row_chunk or 10000
end

-- Spin the event loop until both tiers are empty and no worker is running.
-- Returns true on drain, false on timeout. Safe in headless mode; in an
-- interactive session callers should prefer awaiting callbacks.
function M.drain_blocking(timeout_ms)
  return vim.wait(timeout_ms or 60000, M.is_empty, 10)
end

-- Walk `dir` (non-recursive in this implementation stub; init.lua's scanner
-- handles recursion and ignores) and enqueue_background + drain.
-- Most callers will invoke the streaming scanner directly; this helper is
-- for scripts and tests that want a one-shot blocking scan of a small dir.
function M.scan_blocking(dir, file_matcher, timeout_ms)
  file_matcher = file_matcher or function(n)
    return n:match("%.org$") ~= nil
  end
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return false, "fs_scandir failed: " .. dir
  end
  while true do
    local name, t = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if t == "file" and file_matcher(name) then
      M.enqueue_background(dir .. "/" .. name)
    end
  end
  return M.drain_blocking(timeout_ms)
end

return M
