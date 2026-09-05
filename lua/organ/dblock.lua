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

-- Parse `:k v :k2 v2 ...` into a string->value table. A key is a `:`
-- that starts a word; a value runs to the next key or is a `"..."`
-- string (which keeps its text verbatim, quotes stripped). Bare values
-- are coerced: numbers to numbers, "yes"/"t" and "no"/"nil" to booleans.
function M.parse_params(raw)
  local out = {}
  if not raw or raw == "" then
    return out
  end
  raw = " " .. raw
  local pos = 1
  while true do
    local _, ke, k = raw:find("%f[%S]:(%S+)", pos)
    if not k then
      break
    end
    local vs = raw:find("%S", ke + 1)
    if not vs or raw:sub(vs, vs) == ":" then
      out[k] = ""
      pos = ke + 1
    elseif raw:sub(vs, vs) == '"' then
      local j = vs + 1
      while j <= #raw and raw:sub(j, j) ~= '"' do
        j = j + (raw:sub(j, j) == "\\" and 2 or 1)
      end
      out[k] = raw:sub(vs + 1, j - 1):gsub("\\(.)", "%1")
      pos = j + 1
    else
      local ws = raw:find("%s+:%S", vs)
      local v = raw:sub(vs, (ws or #raw + 1) - 1):gsub("%s+$", "")
      if v == "yes" or v == "t" then
        out[k] = true
      elseif v == "no" or v == "nil" then
        out[k] = false
      elseif tonumber(v) then
        out[k] = tonumber(v)
      else
        out[k] = v
      end
      pos = ws or #raw + 1
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

-- Resolve a `:block` name to (from_iso, to_iso, caption_text).  The caption
-- text is the string Emacs puts after ", for " in the clocktable caption
-- (`org-clock-special-range`: "%A, %B %d, %Y" for a day, "week %G-W%V" for a
-- week, "%B %Y" for a month).
local function resolve_block(name)
  local now_t = os.time()
  local function iso(t)
    return os.date("%Y-%m-%d", t)
  end
  local function week_start(offset_weeks)
    local t = os.date("*t", now_t)
    local dow = t.wday == 1 and 7 or (t.wday - 1)
    return now_t - (dow - 1 + 7 * offset_weeks) * 86400
  end
  if name == "today" then
    return iso(now_t), iso(now_t), os.date("%A, %B %d, %Y", now_t)
  elseif name == "thisweek" or name == "week" then
    local start = week_start(0)
    return iso(start), iso(start + 6 * 86400), "week " .. os.date("%G-W%V", start)
  elseif name == "lastweek" then
    local start = week_start(1)
    return iso(start), iso(start + 6 * 86400), "week " .. os.date("%G-W%V", start)
  elseif name == "thismonth" or name == "month" then
    local t = os.date("*t", now_t)
    local start = os.time({ year = t.year, month = t.month, day = 1, hour = 12 })
    return string.format("%04d-%02d-01", t.year, t.month), iso(now_t), os.date("%B %Y", start)
  elseif name == "lastmonth" then
    local t = os.date("*t", now_t)
    local first_of_this = os.time({ year = t.year, month = t.month, day = 1, hour = 12 })
    local end_of_last = first_of_this - 86400
    local l = os.date("*t", end_of_last)
    return string.format("%04d-%02d-01", l.year, l.month),
      iso(end_of_last),
      os.date("%B %Y", end_of_last)
  end
  return nil, nil, nil
end

-- Format seconds the way `org-duration-from-minutes` does under the default
-- `org-duration-format`: `H:MM`, with a leading `Nd ` once a day is reached.
local function fmt_dur(secs)
  local mins = math.floor((secs or 0) / 60)
  local days = math.floor(mins / 1440)
  local rest = mins - days * 1440
  local hm = string.format("%d:%02d", math.floor(rest / 60), rest % 60)
  if days > 0 then
    return string.format("%dd %s", days, hm)
  end
  return hm
end

-- `org-shorten-string`: cut at the last word boundary that keeps the result,
-- ellipsis included, within `maxlen`.
local function shorten(s, maxlen)
  if #s <= maxlen then
    return s
  end
  local n = math.max(maxlen - 4, 1)
  for i = math.min(n + 1, #s), 2, -1 do
    if s:sub(i, i) ~= " " and s:sub(i + 1, i + 1) == " " then
      return s:sub(1, i) .. "..."
    end
  end
  return s:sub(1, math.max(maxlen - 3, 0)) .. "..."
end

-- `org-clocktable-indent-string`: two spaces per level above 1, behind `\_`.
local function indent_string(level)
  if level <= 1 then
    return ""
  end
  return "\\_" .. string.rep(" ", 2 * (level - 1))
end

-- `org-table-number-regexp` (the default value), which decides whether a
-- column is right-aligned.
local function looks_numeric(cell)
  return cell:match("^[<>]?[-+^.0-9]*%d[-+^.0-9eEdDx()%%:]*$") ~= nil
    or cell:match("^[<>]?[-+]?0[xX][%x.]+$") ~= nil
    or cell:match("^[<>]?[-+]?%d+#[0-9a-zA-Z.]+$") ~= nil
    or cell == "nan"
    or cell:match("^[-+u]?inf$") ~= nil
end

-- Render `rows` (a list of cell lists, or the string "hline") as an aligned
-- org table, following `org-table-align`: column width is the widest cell,
-- and a column right-aligns once at least `org-table-number-fraction` (0.5)
-- of its non-empty cells look like numbers.
local function align_table(rows, ncols)
  local dw = vim.fn.strdisplaywidth
  local widths, aligns = {}, {}
  for ci = 1, ncols do
    local w, numbers, non_empty = 1, 0, 0
    for _, row in ipairs(rows) do
      if row ~= "hline" then
        local cell = row[ci] or ""
        w = math.max(w, dw(cell))
        if cell ~= "" then
          non_empty = non_empty + 1
          if looks_numeric(cell) then
            numbers = numbers + 1
          end
        end
      end
    end
    widths[ci] = w
    aligns[ci] = (numbers >= 0.5 * non_empty) and "r" or "l"
  end

  local out = {}
  for _, row in ipairs(rows) do
    if row == "hline" then
      local cells = {}
      for ci = 1, ncols do
        cells[ci] = string.rep("-", widths[ci] + 2)
      end
      out[#out + 1] = "|" .. table.concat(cells, "+") .. "|"
    else
      local cells = {}
      for ci = 1, ncols do
        local cell = row[ci] or ""
        local pad = string.rep(" ", math.max(0, widths[ci] - dw(cell)))
        cells[ci] = (aligns[ci] == "r") and (pad .. cell) or (cell .. pad)
      end
      out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
  end
  return out
end

-- Subtree totals per headline, in document order, for one file.
local function file_entries(file_path, own_by_id, maxlevel)
  local hs = require("organ.query").headlines({ file = file_path })
  table.sort(hs, function(a, b)
    return (a.line_start or 0) < (b.line_start or 0)
  end)
  local out = {}
  for i, h in ipairs(hs) do
    local total = own_by_id[h.id] or 0
    for j = i + 1, #hs do
      if (hs[j].level or 1) <= (h.level or 1) then
        break
      end
      total = total + (own_by_id[hs[j].id] or 0)
    end
    if total > 0 and (h.level or 1) <= maxlevel then
      out[#out + 1] = { level = h.level or 1, title = h.title or "(unknown)", seconds = total }
    end
  end
  return out
end

-- Default clocktable writer.  Shape follows `org-clocktable-write-default`:
-- a caption, a `Headline | Time` header with one further column per
-- headline level, a `*Total time*` row between two horizontal rules, then
-- one row per entry indented with `\_` and carrying its subtree total in
-- the column for its level.
local function clocktable_writer(params, ctx)
  params = params or {}
  local from, to, period
  if params.block then
    from, to, period = resolve_block(params.block)
  end
  local function date_of(v)
    if type(v) ~= "string" then
      return v
    end
    return v:match("%d%d%d%d%-%d%d%-%d%d") or v
  end
  from = date_of(params.tstart) or from
  to = date_of(params.tend) or to

  local maxlevel = tonumber(params.maxlevel) or 2
  local narrow = tonumber(params.narrow) or 40

  local query = require("organ.query")
  local opts = { from = from, to = to, group_by = "headline" }
  if params.scope == "file" or params.scope == nil then
    opts.file = vim.api.nvim_buf_get_name(ctx.bufnr or 0)
  elseif params.scope == "agenda" then
    -- All indexed files; leave file unset.
  end
  local rows = query.clock_entries(opts)

  if params.fileskip0 == true then
    local kept = {}
    for _, r in ipairs(rows) do
      if (r.total_seconds or 0) > 0 then
        kept[#kept + 1] = r
      end
    end
    rows = kept
  end

  local total, own_by_id, files, seen_file = 0, {}, {}, {}
  for _, r in ipairs(rows) do
    total = total + (r.total_seconds or 0)
    if r.headline_id then
      own_by_id[r.headline_id] = (own_by_id[r.headline_id] or 0) + (r.total_seconds or 0)
    end
    local fp = r.file_path or opts.file
    if fp and not seen_file[fp] then
      seen_file[fp] = true
      files[#files + 1] = fp
    end
  end
  table.sort(files)

  local entries = {}
  for _, fp in ipairs(files) do
    for _, e in ipairs(file_entries(fp, own_by_id, maxlevel)) do
      entries[#entries + 1] = e
    end
  end

  -- Deepest level present caps the number of time columns.
  local deepest = 1
  for _, e in ipairs(entries) do
    deepest = math.max(deepest, e.level)
  end
  local time_columns = (maxlevel < 2) and 1 or math.min(maxlevel, deepest)
  local ncols = 2 + (time_columns - 1)

  local function blank_row()
    local r = {}
    for i = 1, ncols do
      r[i] = ""
    end
    return r
  end

  local table_rows = {}
  local header = blank_row()
  header[1], header[2] = "Headline", "Time"
  table_rows[#table_rows + 1] = header
  table_rows[#table_rows + 1] = "hline"
  local total_row = blank_row()
  total_row[1], total_row[2] = "*Total time*", "*" .. fmt_dur(total) .. "*"
  table_rows[#table_rows + 1] = total_row
  if total > 0 and #entries > 0 then
    table_rows[#table_rows + 1] = "hline"
    for _, e in ipairs(entries) do
      local row = blank_row()
      row[1] = indent_string(e.level) .. shorten(e.title, narrow)
      row[1 + math.min(e.level, time_columns)] = fmt_dur(e.seconds)
      table_rows[#table_rows + 1] = row
    end
  end

  local out = {
    string.format(
      "#+CAPTION: Clock summary at %s%s",
      os.date("[%Y-%m-%d %a %H:%M]"),
      period and (", for " .. period .. ".") or ""
    ),
  }
  for _, l in ipairs(align_table(table_rows, ncols)) do
    out[#out + 1] = l
  end
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
    while i >= 1 and not (lines[i] or ""):match("^%*+ ") do
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
