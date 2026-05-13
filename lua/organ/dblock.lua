-- Dynamic blocks (Emacs `org-dblock`).
--
-- Recognises:
--   #+BEGIN: NAME :param1 value1 :param2 value2
--   …generated body…
--   #+END:
--
-- :Org update_dblock regenerates the body of the dblock at cursor (or every
-- dblock in the buffer when no dblock contains cursor). Built-in writers:
--   clocktable    — clock-time table aggregated per :scope
--
-- Register custom writers:
--   require("organ.dblock").register("myblock", function(params) return {lines} end)

local M = {}

local obuf = require("organ.buf")
M.writers = {}

-- Parse `:k v :k2 v2 …` into a string→value table. Numeric strings are
-- coerced to numbers; "yes"/"no" to booleans; everything else stays string.
function M.parse_params(raw)
  local out = {}
  if not raw or raw == "" then
    return out
  end
  for k, v in raw:gmatch(":(%S+)%s+([^:]*)") do
    v = v:gsub("%s+$", "")
    if v == "yes" or v == "t" then
      out[k] = true
    elseif v == "no" or v == "nil" then
      out[k] = false
    elseif tonumber(v) then
      out[k] = tonumber(v)
    else
      out[k] = v
    end
  end
  return out
end

-- Find the dblock containing `lnum` (1-based). Returns
-- { name, params_raw, params, header_line, end_line } or nil.
function M.find_dblock_at(bufnr, lnum)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Walk up from cursor for #+BEGIN:
  local begin
  for i = lnum, 1, -1 do
    local l = lines[i] or ""
    if l:lower():match("^%s*#%+end:") then
      return nil
    end
    if l:lower():match("^%s*#%+begin:") then
      begin = i
      break
    end
  end
  if not begin then
    return nil
  end
  -- Walk down for #+END:
  local end_idx
  for i = begin + 1, #lines do
    if (lines[i] or ""):lower():match("^%s*#%+end:") then
      end_idx = i
      break
    end
  end
  if not end_idx then
    return nil
  end
  local hdr = lines[begin] or ""
  local name, raw = hdr:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+(%S+)%s*(.-)$")
  if not name then
    return nil
  end
  return {
    name = name,
    params_raw = raw,
    params = M.parse_params(raw),
    header_line = begin,
    end_line = end_idx,
  }
end

-- All dblocks in the buffer (in order).
function M.find_all(bufnr)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  local i = 1
  while i <= #lines do
    if (lines[i] or ""):lower():match("^%s*#%+begin:") then
      local hit = M.find_dblock_at(bufnr, i)
      if hit then
        out[#out + 1] = hit
        i = hit.end_line
      end
    end
    i = i + 1
  end
  return out
end

-- Replace the body of an already-located dblock with new_body_lines.
function M.replace_body(bufnr, db, new_body_lines)
  -- Body lives between header_line and end_line (exclusive of both).
  obuf.set_lines(bufnr, db.header_line, db.end_line - 1, new_body_lines)
end

-- Update one dblock by name/params. Returns (true, n_lines_written) on
-- success, (false, err) when no writer is registered.
function M.update(bufnr, db)
  local writer = M.writers[db.name]
  if not writer then
    return false, "no writer for dblock '" .. db.name .. "'"
  end
  local body = writer(db.params, { bufnr = bufnr, dblock = db })
  if type(body) ~= "table" then
    body = { tostring(body) }
  end
  M.replace_body(bufnr, db, body)
  return true, #body
end

-- Update the dblock at cursor.
function M.update_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local db = M.find_dblock_at(bufnr, lnum)
  if not db then
    return false, "no #+BEGIN: dblock at cursor"
  end
  return M.update(bufnr, db)
end

-- Update every dblock in the buffer.
function M.update_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local n_ok, n_err = 0, 0
  -- Walk in reverse so insertions/deletions don't shift later block ranges.
  local all = M.find_all(bufnr)
  for i = #all, 1, -1 do
    local ok = M.update(bufnr, all[i])
    if ok then
      n_ok = n_ok + 1
    else
      n_err = n_err + 1
    end
  end
  return n_ok, n_err
end

-- Register a writer. fn(params, ctx) returns a list of body lines.
function M.register(name, fn)
  M.writers[name] = fn
end

-- Built-in: clocktable.

local function resolve_block(name)
  -- "today" / "thisweek" / "lastweek" / "thismonth" / "lastmonth" → ISO range.
  local now_t = os.time()
  local function iso(t)
    return os.date("%Y-%m-%d", t)
  end
  if name == "today" then
    return iso(now_t), iso(now_t)
  elseif name == "thisweek" or name == "week" then
    -- Week start: Monday. wday 1=Sunday, 2=Monday in Lua os.date.
    local t = os.date("*t", now_t)
    local dow = t.wday == 1 and 7 or (t.wday - 1)
    local start = now_t - (dow - 1) * 86400
    return iso(start), iso(start + 6 * 86400)
  elseif name == "lastweek" then
    local t = os.date("*t", now_t)
    local dow = t.wday == 1 and 7 or (t.wday - 1)
    local start = now_t - (dow - 1 + 7) * 86400
    return iso(start), iso(start + 6 * 86400)
  elseif name == "thismonth" or name == "month" then
    local t = os.date("*t", now_t)
    return string.format("%04d-%02d-01", t.year, t.month), iso(now_t)
  elseif name == "lastmonth" then
    local t = os.date("*t", now_t)
    local last_m = t.month == 1 and 12 or (t.month - 1)
    local last_y = t.month == 1 and (t.year - 1) or t.year
    -- Last day of previous month: subtract 1 day from first of current month.
    local end_of_last = os.time({ year = t.year, month = t.month, day = 1, hour = 12 }) - 86400
    return string.format("%04d-%02d-01", last_y, last_m), iso(end_of_last)
  end
  return nil, nil
end

-- Format seconds as `H:MM` (Emacs convention).
local function fmt_dur(secs)
  local mins = math.floor((secs or 0) / 60)
  return string.format("%d:%02d", math.floor(mins / 60), mins % 60)
end

-- Default clocktable writer.
local function clocktable_writer(params, ctx)
  params = params or {}
  local from, to
  if params.block then
    from, to = resolve_block(params.block)
  end
  from = params.tstart or from
  to = params.tend or to

  local query = require("organ.query")
  local opts = { from = from, to = to, group_by = "headline" }
  if params.scope == "file" or params.scope == nil then
    opts.file = vim.api.nvim_buf_get_name(ctx.bufnr or 0)
  elseif params.scope == "agenda" then
    -- All indexed files; leave file unset.
  end
  local rows = query.clock_entries(opts)

  -- Optionally hide rows with 0 duration.
  if params.fileskip0 == true then
    local kept = {}
    for _, r in ipairs(rows) do
      if (r.total_seconds or 0) > 0 then
        kept[#kept + 1] = r
      end
    end
    rows = kept
  end

  -- Compute widths.
  local title_w = #"Headline"
  local time_w = #"Time"
  local total = 0
  for _, r in ipairs(rows) do
    title_w = math.max(title_w, #(r.title or ""))
    time_w = math.max(time_w, #fmt_dur(r.total_seconds or 0))
    total = total + (r.total_seconds or 0)
  end
  time_w = math.max(time_w, #fmt_dur(total))

  local function row(a, b)
    return string.format("| %-" .. title_w .. "s | %-" .. time_w .. "s |", a, b)
  end
  local function sep()
    return "|" .. string.rep("-", title_w + 2) .. "+" .. string.rep("-", time_w + 2) .. "|"
  end

  local out = {}
  out[#out + 1] = string.format(
    "#+CAPTION: Clock summary at [%s]%s%s",
    os.date("%Y-%m-%d %H:%M"),
    from and (", from " .. from) or "",
    to and (", to " .. to) or ""
  )
  out[#out + 1] = row("Headline", "Time")
  out[#out + 1] = sep()
  for _, r in ipairs(rows) do
    out[#out + 1] = row(r.title or "(unknown)", fmt_dur(r.total_seconds or 0))
  end
  out[#out + 1] = sep()
  out[#out + 1] = row("TOTAL", fmt_dur(total))
  return out
end

M.register("clocktable", clocktable_writer)

-- Built-in: columnview.
--
-- Embedded column view (uses #+COLUMNS or :COLUMNS:). The dblock body is
-- replaced with the rendered column table.
local function columnview_writer(_, ctx)
  local cv = require("organ.column_view")
  local bufnr = ctx.bufnr or 0
  local anchor_line = ctx.dblock and ctx.dblock.header_line or 1
  local spec, root_line = cv.find_spec(bufnr, anchor_line)
  if not spec then
    return { "(no #+COLUMNS or :COLUMNS: in scope)" }
  end
  local cols = cv.parse_spec(spec)
  if #cols == 0 then
    return { "(empty column spec)" }
  end
  local rows = cv.collect(bufnr, root_line, cols)
  cv.apply_summaries(rows, cols)
  return cv.render(rows, cols)
end

M.register("columnview", columnview_writer)

-- Built-in: propertyview.
--
-- Renders a table of headlines × explicit property names. Params:
--   :scope file|tree    file = whole buffer; tree = subtree owning the dblock
--   :props "PRIO TAGS"  space-separated property names (default ITEM)
local function propertyview_writer(params, ctx)
  params = params or {}
  local bufnr = ctx.bufnr or 0
  local cv = require("organ.column_view")

  local props = {}
  for p in tostring(params.props or "ITEM"):gmatch("%S+") do
    props[#props + 1] = p
  end
  if #props == 0 then
    return { "(no :props)" }
  end

  local cols = {}
  for _, p in ipairs(props) do
    cols[#cols + 1] = { property = p, label = p }
  end

  local root_line
  if params.scope == "tree" and ctx.dblock then
    -- Climb to the headline owning the dblock.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local i = ctx.dblock.header_line
    while i >= 1 and not (lines[i] or ""):match("^%*+%s") do
      i = i - 1
    end
    if i >= 1 then
      root_line = i
    end
  end
  local rows = cv.collect(bufnr, root_line, cols)
  return cv.render(rows, cols)
end

M.register("propertyview", propertyview_writer)

M.commands = {
  update_dblock = {
    fn = function()
      local ok, msg = M.update_at_cursor()
      if not ok then
        require("organ.notify").warn(tostring(msg))
      else
        require("organ.notify").info(("dblock updated (%d body lines)"):format(msg or 0))
      end
    end,
    desc = "Regenerate the body of the #+BEGIN: dblock at cursor (Emacs C-c C-x C-u)",
  },
  update_all_dblocks = {
    fn = function()
      local n_ok, n_err = M.update_all()
      require("organ.notify").info(("%d dblock(s) updated, %d error(s)"):format(n_ok, n_err))
    end,
    desc = "Regenerate every #+BEGIN: dblock in the current buffer",
  },
}

return M
