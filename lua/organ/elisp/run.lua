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

M.CODES = {}
for code in
  ([[syntax function special free-variable setq-global regexp nan unprintable eq-identity
  locale width case-special cycle charset holidays precision profile internal]]):gmatch("%S+")
do
  M.CODES[code] = true
end

local hrtime = vim.uv.hrtime

--- Signal (SYMBOL . DATA); `obj` is the error object itself when the
--- caller has one (signal with a nil symbol), else it is built on demand.
function M.signal(symbol, data, obj)
  error({ elisp = "signal", symbol = symbol, data = data, obj = obj }, 0)
end

--- Refuse with `code`.  A refusal over particular values (a NaN, a
--- character, two boxes) passes them as a third argument, which the
--- conformance trace records.
function M.refuse(code, detail)
  error({ elisp = "refused", code = code, detail = detail }, 0)
end

function M.limit(cap)
  error({ elisp = "limit", cap = cap }, 0)
end

local Run = {}
Run.__index = Run

local function bad(what, v)
  M.refuse("internal", ("%s: %s"):format(what, tostring(v)))
end

local function cap_value(name, v, default)
  if v == nil then
    return default
  elseif type(v) ~= "number" or v ~= v or v < 0 then
    bad("caps." .. name, v)
  end
  return math.min(v, default)
end

local function used_value(budget, name)
  local v = budget[name]
  if v == nil then
    return 0
  elseif type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
    bad("budget." .. name, v)
  end
  return v
end

--- State for one call under `ctx` (its `caps` and `budget`).  Under
--- `parent`, the run of a call still in progress, the call is nested:
--- it gets at most the parent's remaining steps, alloc and time and the
--- parent's caps, and its depth continues the parent's.
function M.new(ctx, parent)
  ctx = ctx or {}
  if type(ctx) ~= "table" then
    bad("ctx", ctx)
  end
  local lower = ctx.caps or {}
  local budget = ctx.budget
  if type(lower) ~= "table" then
    bad("caps", lower)
  elseif budget ~= nil and type(budget) ~= "table" then
    bad("budget", budget)
  end
  local syntax_table = ctx.syntax_table or "org"
  if syntax_table ~= "org" and syntax_table ~= "agenda" then
    bad("syntax_table", syntax_table)
  end
  local caps = {}
  for name, default in pairs(M.DEFAULTS) do
    caps[name] = cap_value(name, lower[name], parent and parent.caps[name] or default)
  end
  local used = budget or {}
  local t0 = hrtime()
  local steps_lim = caps.steps - used_value(used, "steps")
  local alloc_lim = caps.alloc - used_value(used, "alloc")
  local time_lim = (caps.time - used_value(used, "time")) * 1e6
  local depth = 0
  if parent then
    steps_lim = math.min(steps_lim, parent.steps_lim - parent.steps)
    alloc_lim = math.min(alloc_lim, parent.alloc_lim - parent.alloc)
    time_lim = math.min(time_lim, parent.time_lim - (t0 - parent.t0))
    depth = parent.depth
    local p = parent
    while p and budget do
      if p.ctx.budget == budget then
        budget = nil
      end
      p = p.parent
    end
  end
  return setmetatable({
    ctx = ctx,
    syntax_table = syntax_table,
    caps = caps,
    budget = budget,
    parent = parent,
    steps = 0,
    alloc = 0,
    depth = depth,
    depth0 = depth,
    tick = 0,
    t0 = t0,
    steps_lim = steps_lim,
    alloc_lim = alloc_lim,
    time_lim = time_lim,
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

--- Add this call's use to `ctx.budget` (unless an enclosing call
--- charges the same budget) and to the parent's counters; a limit
--- `cap` the call hit stays with the parent.
function Run:settle(cap)
  if self.settled then
    return
  end
  self.settled = true
  local b = self.budget
  if b then
    b.steps = (b.steps or 0) + self.steps
    b.alloc = (b.alloc or 0) + self.alloc
    b.time = (b.time or 0) + (hrtime() - self.t0) / 1e6
  end
  local p = self.parent
  if p then
    p.steps = p.steps + self.steps
    p.alloc = p.alloc + self.alloc
    p.limited = p.limited or cap
  end
end

--- Raise the limit a nested call hit, once control is back in this run.
function Run:check_nested()
  if self.limited then
    M.limit(self.limited)
  end
end

return M
