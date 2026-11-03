-- organ side of the elisp conformance gate: reads (and in `eval' mode
-- evaluates) each item of a case through organ.elisp and prints one
-- line per item in the shape emacs.el prints (see NORMALIZE.md).
--
-- Evaluation is traced: each builtin call a Lisp form makes is recorded
-- by name (the builtin-coverage check), and a refusal keeps the builtin
-- calls active when it was raised (the fuzz classifier).

-- Loaded by M.render, so M.parse and M.zone work before the gate sets
-- up the runtime path.
local elisp

local M = {}

local MODES = { read = true, eval = true }

-- One trace per process, shared by every load of this file: { calls =
-- set of builtin names called from Lisp, stack = active builtin calls
-- (frames { name, argv, fold, pre }), refusals = { code, detail, frames, seen }
-- in the order raised since the last reset (`seen`: the values the
-- refusal is about, when it names them), pre = { name = fn(argv) }
-- whose value a call of builtin `name` keeps as its frame's `pre` }.
local TRACE_KEY = "organ.elisp conformance trace"

function M.trace()
  local t = package.loaded[TRACE_KEY]
  if t then
    return t
  end
  t = { calls = {}, stack = {}, depth = 0, refusals = {}, pre = {} }
  package.loaded[TRACE_KEY] = t
  local B = require("organ.elisp.builtins")
  local R = require("organ.elisp.run")
  local E = require("organ.elisp.eval")
  local eval_source = debug.getinfo(E.eval, "S").source
  for name, def in pairs(B.defs) do
    local fn = def.fn
    def.fn = function(run, argv)
      if debug.getinfo(2, "S").source == eval_source then
        t.calls[name] = true
      end
      local d = t.depth + 1
      t.depth = d
      local pre = t.pre[name]
      t.stack[d] = { name = name, argv = argv, fold = E.case_fold(run), pre = pre and pre(argv) }
      local ok, v = pcall(fn, run, argv)
      t.stack[d] = nil
      t.depth = d - 1
      if not ok then
        error(v, 0)
      end
      return v
    end
  end
  local refuse = R.refuse
  R.refuse = function(code, detail, seen)
    local frames = {}
    for i = 1, t.depth do
      frames[i] = t.stack[i]
    end
    t.refusals[#t.refusals + 1] = { code = code, detail = detail, frames = frames, seen = seen }
    return refuse(code, detail)
  end
  return t
end

local function blocks_of(text)
  local blocks, cur = {}, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line == "" then
      if cur then
        blocks[#blocks + 1] = cur
        cur = nil
      end
    else
      cur = cur or {}
      cur[#cur + 1] = line
    end
  end
  if cur then
    blocks[#blocks + 1] = cur
  end
  return blocks
end

--- Header and items of case text: header is a key -> value map of the
--- first block's `; key: value` lines; each item is { naive, source }.
function M.parse(text)
  local blocks = blocks_of(text)
  local header = {}
  for _, l in ipairs(blocks[1] or {}) do
    if l:sub(1, 1) ~= ";" then
      error("case has no header block")
    end
    local k, v = l:match("^; ([a-z_]+): *(.*)$")
    if k then
      header[k] = v
    end
  end
  local items = {}
  for b = 2, #blocks do
    local lines = blocks[b]
    local naive
    local i = 1
    while lines[i] and lines[i]:sub(1, 9) == "; naive: " do
      naive = lines[i]:sub(10)
      i = i + 1
    end
    items[#items + 1] = { naive = naive, source = table.concat(lines, "\n", i) }
  end
  return header, items
end

local function oneline(s)
  return (s:gsub("\n", "\\n"))
end

local function failure_line(r)
  if r.kind == "signal" then
    return "!! " .. (r.text and oneline(r.text) or (r.symbol .. " <unprintable>"))
  elseif r.kind == "refused" then
    return "REFUSED " .. r.code .. (r.detail and (" " .. oneline(r.detail)) or "")
  end
  return "LIMIT " .. r.cap
end

local function value_line(v)
  local p = elisp.prin1(v, { escape_newlines = true })
  if not p.ok then
    return failure_line(p)
  end
  return "=> " .. p.value
end

local function read_item(source)
  local r = elisp.read(source, 1)
  if not r.ok then
    return failure_line(r)
  end
  return value_line(r.value)
end

--- The ctx of one item of a case with `header`: `date` is read afresh
--- for each item, as emacs.el reads it, so a form that changes it
--- destructively does not reach the next item.
function M.ctx_of(header)
  elisp = elisp or require("organ.elisp")
  local variables = {}
  if header.date then
    local d = elisp.read(header.date)
    assert(d.ok, "case date does not read")
    variables.date = d.value
  end
  if header.entry then
    variables.entry = header.entry
  end
  return { profile = header.profile, case_fold = header.case_fold == "t", variables = variables }
end

--- The output line of evaluating `source` under `ctx`, and the result
--- (`value` holds the evaluated value when it printed or failed to).
function M.eval_line(source, ctx)
  elisp = elisp or require("organ.elisp")
  local r = elisp.eval_string(source, ctx)
  if not r.ok then
    return failure_line(r), r
  end
  return value_line(r.value), r
end

local function eval_item(source, ctx)
  return (M.eval_line(source, ctx))
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- The `tz` header of the case at `path`: the zone its run sets TZ to,
--- nil for the UTC run (and for a missing file).
function M.zone(path)
  local text = read(path)
  return text and M.parse(text).tz or nil
end

function M.render(path)
  elisp = elisp or require("organ.elisp")
  M.trace()
  local text = assert(read(path))
  local header, items = M.parse(text)
  if not MODES[header.mode] then
    error("unknown mode " .. tostring(header.mode))
  end
  if os.getenv("TZ") ~= (header.tz or "UTC") then
    error("case for TZ=" .. (header.tz or "UTC") .. " run with TZ=" .. tostring(os.getenv("TZ")))
  end
  local out = {}
  for _, item in ipairs(items) do
    local line = header.mode == "eval" and eval_item(item.source, M.ctx_of(header))
      or read_item(item.source)
    out[#out + 1] = line .. "\n"
  end
  return table.concat(out)
end

return M
