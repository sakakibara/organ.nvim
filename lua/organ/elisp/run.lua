-- Per-call evaluation state: the caps every entry point is charged
-- against, and the errors that end a call.  signal, refuse and limit
-- raise a tagged table that the entry wrapper (organ.elisp) turns into a
-- result.

local M = {}

M.DEFAULTS = {
  steps = 200000,
  depth = 400,
  string = 1048576,
  list = 100000,
  alloc = 32 * 1048576,
  time = 1000,
}

local hrtime = vim.uv.hrtime

--- Signal (SYMBOL . DATA); `obj` is the error object itself when the
--- caller has one (signal with a nil symbol), else it is built on demand.
function M.signal(symbol, data, obj)
  error({ elisp = "signal", symbol = symbol, data = data, obj = obj }, 0)
end

function M.refuse(code, detail)
  error({ elisp = "refused", code = code, detail = detail }, 0)
end

function M.limit(cap)
  error({ elisp = "limit", cap = cap }, 0)
end

local Run = {}
Run.__index = Run

--- State for one call under `ctx` (its `caps` and `budget`).
function M.new(ctx)
  ctx = ctx or {}
  local caps = {}
  local lower = ctx.caps or {}
  for name, default in pairs(M.DEFAULTS) do
    local v = lower[name]
    caps[name] = (type(v) == "number" and v < default) and v or default
  end
  local budget = ctx.budget
  local used = budget or {}
  return setmetatable({
    ctx = ctx,
    caps = caps,
    budget = budget,
    steps = 0,
    alloc = 0,
    depth = 0,
    tick = 0,
    t0 = hrtime(),
    steps_lim = caps.steps - (used.steps or 0),
    alloc_lim = caps.alloc - (used.alloc or 0),
    time_lim = (caps.time - (used.time or 0)) * 1e6,
  }, Run)
end

function Run:step(n)
  local s = self.steps + (n or 1)
  self.steps = s
  if s > self.steps_lim then
    M.limit("steps")
  end
  if s - self.tick >= 1024 then
    self.tick = s
    self:check_time()
  end
end

function Run:check_time()
  if hrtime() - self.t0 > self.time_lim then
    M.limit("time")
  end
end

function Run:charge(bytes)
  local a = self.alloc + bytes
  self.alloc = a
  if a > self.alloc_lim then
    M.limit("alloc")
  end
end

function Run:enter()
  local d = self.depth + 1
  if d > self.caps.depth then
    M.limit("depth")
  end
  self.depth = d
end

function Run:leave()
  self.depth = self.depth - 1
end

function Run:check_string(bytes)
  if bytes > self.caps.string then
    M.limit("string")
  end
end

function Run:check_list(n)
  if n > self.caps.list then
    M.limit("list")
  end
end

--- Add this call's use to `ctx.budget`.
function Run:settle()
  local b = self.budget
  if b then
    b.steps = (b.steps or 0) + self.steps
    b.alloc = (b.alloc or 0) + self.alloc
    b.time = (b.time or 0) + (hrtime() - self.t0) / 1e6
  end
end

return M
