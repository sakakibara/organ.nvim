-- Lightweight per-call profiler for organ's hot paths.
--
-- Wraps a small set of functions (indexer.extract, indexer.write_body,
-- agenda.refresh, query.*) so each invocation logs its wall-clock
-- duration. Slow calls (default >=50 ms) are flagged.
--
-- Usage:
--   :Org profile start       -- begin recording
--   <do whatever feels slow>
--   :Org profile stop        -- stop and emit a summary
--   :Org profile report      -- show aggregate stats so far without stopping
--
-- Off by default. Once started, every wrapped call appends a row to an
-- in-memory buffer; the report sorts by total time and shows the worst
-- offenders. The wrapper is a no-op when not started, so the cost of
-- having it loaded is one boolean check per wrapped call.

local M = {}

M._enabled = false
M.frame_enabled = false -- decoration redraw-path timing (per-frame, higher overhead)
M._slow_ms = 50
M._records = {}
M._wrapped = false -- so multiple :Org profile start calls don't double-wrap

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function record(name, dt_ms, extra)
  if not (M._enabled or M.frame_enabled) then
    return
  end
  local r = M._records[name]
  if not r then
    r = { count = 0, total_ms = 0, max_ms = 0, slow_count = 0, examples = {} }
    M._records[name] = r
  end
  r.count = r.count + 1
  r.total_ms = r.total_ms + dt_ms
  if dt_ms > r.max_ms then
    r.max_ms = dt_ms
  end
  if dt_ms >= M._slow_ms then
    r.slow_count = r.slow_count + 1
    if #r.examples < 5 then
      r.examples[#r.examples + 1] = { dt_ms = dt_ms, extra = extra, ts = os.time() }
    end
  end
end

-- Wrap a method on a module table so its call goes through the profiler.
-- Idempotent — once-wrapped, returns early.
local function wrap(mod_name, fn_name, label_arg_idx)
  local ok, mod = pcall(require, mod_name)
  if not ok or type(mod) ~= "table" or type(mod[fn_name]) ~= "function" then
    return
  end
  local key = mod_name .. "." .. fn_name
  if mod["__organ_profile_" .. fn_name] then
    return
  end
  local orig = mod[fn_name]
  mod["__organ_profile_" .. fn_name] = orig
  mod[fn_name] = function(...)
    if not M._enabled then
      return orig(...)
    end
    local args = { ... }
    local label = label_arg_idx and tostring(args[label_arg_idx] or "") or ""
    local t0 = now_ms()
    -- pcall so timing always gets recorded — otherwise an erroring
    -- call (which still consumed wall time) would silently disappear
    -- from the report and the user would think nothing happened.
    local ok, r1, r2, r3, r4 = pcall(orig, ...)
    record(key, now_ms() - t0, label)
    if not ok then
      error(r1, 0)
    end
    return r1, r2, r3, r4
  end
end

-- Wrap a top-level function on a module via key path "mod.field.fn".
-- (We only need a flat one-level wrap right now; broader cases can call
-- M.wrap directly.)
M.wrap = wrap

-- Record a single decoration-frame sample.  Call sites guard on
-- M.frame_enabled before timing so the disabled path costs one field read.
function M.record_frame(name, dt_ms, extra)
  record(name, dt_ms, extra)
end

-- Default wrapping set. Each entry: { module, fn, optional label arg index }.
local DEFAULT_WRAPS = {
  { "organ", "drain_blocking" },
  { "organ.indexer", "extract", 2 }, -- 2nd arg is path
  { "organ.indexer", "write_body" },
  { "organ.agenda", "refresh" },
  { "organ.agenda", "render" },
  { "organ.query", "agenda" },
  { "organ.query", "headlines" },
  { "organ.query", "links_to" },
}

local function ensure_wrapped()
  if M._wrapped then
    return
  end
  M._wrapped = true
  for _, w in ipairs(DEFAULT_WRAPS) do
    wrap(w[1], w[2], w[3])
  end
end

function M.start(opts)
  opts = opts or {}
  if opts.slow_ms then
    M._slow_ms = opts.slow_ms
  end
  M._records = {}
  ensure_wrapped()
  M._enabled = true
  M.frame_enabled = true
  return true
end

function M.stop()
  M._enabled = false
  M.frame_enabled = false
  return M.report()
end

function M.report()
  -- Sort by total wall time descending.
  local rows = {}
  for name, r in pairs(M._records) do
    rows[#rows + 1] = {
      name = name,
      count = r.count,
      total_ms = r.total_ms,
      max_ms = r.max_ms,
      slow_count = r.slow_count,
      avg_ms = r.count > 0 and (r.total_ms / r.count) or 0,
      examples = r.examples,
    }
  end
  table.sort(rows, function(a, b)
    return a.total_ms > b.total_ms
  end)

  local lines = {
    "organ profile report  (slow threshold: " .. M._slow_ms .. " ms)",
    string.format(
      "%-32s  %6s  %9s  %9s  %9s  %6s",
      "function",
      "count",
      "total ms",
      "avg ms",
      "max ms",
      "slow"
    ),
    string.rep("-", 80),
  }
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format(
      "%-32s  %6d  %9.1f  %9.1f  %9.1f  %6d",
      r.name,
      r.count,
      r.total_ms,
      r.avg_ms,
      r.max_ms,
      r.slow_count
    )
  end

  -- Per-function slow examples
  local sample_lines = {}
  for _, r in ipairs(rows) do
    if r.slow_count > 0 then
      sample_lines[#sample_lines + 1] = ""
      sample_lines[#sample_lines + 1] = "Slow examples — " .. r.name .. ":"
      for _, ex in ipairs(r.examples) do
        sample_lines[#sample_lines + 1] =
          string.format("  %.1f ms  %s", ex.dt_ms, tostring(ex.extra or ""))
      end
    end
  end
  for _, l in ipairs(sample_lines) do
    lines[#lines + 1] = l
  end

  local out = table.concat(lines, "\n")
  print(out)
  return rows, out
end

-- Status accessor for tests / commands.
function M.is_enabled()
  return M._enabled
end

return M
