-- Diary-style sexp dates for org-mode.
--
-- Recognised forms.  `diary-*` take Emacs's default `calendar-date-style`
-- (american: MONTH DAY YEAR); the `org-*` variants take ISO order
-- (YEAR MONTH DAY):
--   <%%(diary-date M D Y)>  <%%(org-date Y M D)>
--       single date (any of M/D/Y may be `t` for wildcard)
--   <%%(diary-anniversary M D Y?)>  <%%(org-anniversary Y M D)>
--       every year on M D after the start year Y (any year when omitted)
--   <%%(diary-cyclic N M D Y)>  <%%(org-cyclic N Y M D)>
--       every N days starting from the date
--   <%%(diary-block M1 D1 Y1 M2 D2 Y2)>  <%%(org-block Y1 M1 D1 Y2 M2 D2)>
--       every day in [start, end] inclusive
--   <%%(diary-float MONTH DOW NTH)>
--       Nth weekday of month (DOW: 0=Sun..6=Sat; MONTH=t for every month,
--       else 1..12)
--
-- Anything else (including arbitrary `if`/lambda predicates) is rejected:
-- evaluating untrusted elisp is out of scope.
--
-- All dates are ISO "YYYY-MM-DD" strings.

local M = {}

local function iso_to_components(iso)
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return tonumber(y), tonumber(m), tonumber(d)
end

local function iso_to_time(iso)
  local y, m, d = iso_to_components(iso)
  if not y then
    return nil
  end
  return os.time({ year = y, month = m, day = d, hour = 12 })
end

-- 0 = Sunday, 6 = Saturday — matching Emacs.
local function dow(iso)
  local t = iso_to_time(iso)
  if not t then
    return nil
  end
  return tonumber(os.date("%w", t))
end

-- Count which occurrence of its weekday this date is in its month: returns
-- 1 for the first Wed of the month, 2 for the second, etc.
local function nth_dow_in_month(iso)
  local _, _, d = iso_to_components(iso)
  return math.ceil(d / 7)
end

local function is_last_dow_in_month(iso)
  local y, m, d = iso_to_components(iso)
  -- Find the last day of this month.
  local next_first = os.time({ year = y, month = m + 1, day = 1, hour = 12 })
  local last_day_iso = os.date("%Y-%m-%d", next_first - 86400)
  local _, _, last_d = iso_to_components(last_day_iso)
  return (last_d - d) < 7
end

-- Parser. Each `parse_*` returns a normalised AST node or nil.

local function tokenize(s)
  -- Strip the surrounding `<%%(` and `)>` if present.
  s = s:gsub("^%s*<%%%%%((.-)%)>%s*$", "%1")
  s = s:gsub("^%s*%((.-)%)%s*$", "%1")
  local tokens = {}
  for tok in s:gmatch("%S+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

local function as_int_or_t(tok)
  if tok == "t" or tok == "nil" then
    return tok
  end
  local n = tonumber(tok)
  return n
end

function M.parse(s)
  local toks = tokenize(s or "")
  if #toks == 0 then
    return nil
  end
  local fn = toks[1]
  local argc = #toks - 1
  local function int(i)
    return tonumber(toks[i])
  end
  -- diary-* forms take Emacs's default american order (M D Y); the iso
  -- order (Y M D) is accepted too, recognised by a leading year (a number
  -- above 31, or the `t` wildcard when the last value is a plain day).
  local function mdy(i)
    local a, b, c = toks[i], toks[i + 1], toks[i + 2]
    local an, cn = tonumber(a), tonumber(c)
    local year_last = c == "t" or (cn and cn > 31)
    local year_first = (an and an > 31) or (a == "t" and not year_last)
    if year_first then
      return as_int_or_t(b), as_int_or_t(c), as_int_or_t(a)
    end
    return as_int_or_t(a), as_int_or_t(b), as_int_or_t(c)
  end
  if fn == "diary-date" and argc == 3 then
    local m, d, y = mdy(2)
    return { kind = "date", m = m, d = d, y = y }
  end
  if fn == "org-date" and argc == 3 then
    return {
      kind = "date",
      y = as_int_or_t(toks[2]),
      m = as_int_or_t(toks[3]),
      d = as_int_or_t(toks[4]),
    }
  end
  if fn == "diary-anniversary" and (argc == 2 or argc == 3) then
    local m, d, y = int(2), int(3), int(4)
    if argc == 3 then
      m, d, y = mdy(2)
    end
    if type(m) == "number" and type(d) == "number" and (argc == 2 or type(y) == "number") then
      return { kind = "anniversary", y = y, m = m, d = d }
    end
  end
  if fn == "org-anniversary" and argc == 3 then
    local y, m, d = int(2), int(3), int(4)
    if y and m and d then
      return { kind = "anniversary", y = y, m = m, d = d }
    end
  end
  if fn == "diary-cyclic" and argc == 4 then
    local n = int(2)
    local m, d, y = mdy(3)
    if n and type(y) == "number" and type(m) == "number" and type(d) == "number" then
      return { kind = "cyclic", n = n, y = y, m = m, d = d }
    end
  end
  if fn == "org-cyclic" and argc == 4 then
    local n, y, m, d = int(2), int(3), int(4), int(5)
    if n and y and m and d then
      return { kind = "cyclic", n = n, y = y, m = m, d = d }
    end
  end
  if fn == "diary-block" and argc == 6 then
    local m1, d1, y1 = mdy(2)
    local m2, d2, y2 = mdy(5)
    if
      type(y1) == "number"
      and type(m1) == "number"
      and type(d1) == "number"
      and type(y2) == "number"
      and type(m2) == "number"
      and type(d2) == "number"
    then
      return { kind = "block", y1 = y1, m1 = m1, d1 = d1, y2 = y2, m2 = m2, d2 = d2 }
    end
  end
  if fn == "org-block" and argc == 6 then
    local y1, m1, d1 = int(2), int(3), int(4)
    local y2, m2, d2 = int(5), int(6), int(7)
    if y1 and m1 and d1 and y2 and m2 and d2 then
      return { kind = "block", y1 = y1, m1 = m1, d1 = d1, y2 = y2, m2 = m2, d2 = d2 }
    end
  end
  if fn == "diary-float" then
    -- diary-float MONTH DAYNAME N
    -- Emacs signature has MONTH first; we accept (DAYNAME N MONTH?) too for
    -- flexibility. For our subset: MONTH=t for every month, DAYNAME=0..6,
    -- N=1..5 (negative = from end of month).
    local month = toks[2] == "t" and "t" or tonumber(toks[2])
    local dayname = tonumber(toks[3])
    local n = tonumber(toks[4])
    if month and dayname and n then
      return { kind = "float", month = month, dayname = dayname, n = n }
    end
  end
  return nil -- unknown / unsupported form
end

-- Matcher.

function M.matches(node, iso_date)
  if not node then
    return false
  end
  local y, m, d = iso_to_components(iso_date)
  if not y then
    return false
  end

  if node.kind == "date" then
    return (node.y == "t" or node.y == y)
      and (node.m == "t" or node.m == m)
      and (node.d == "t" or node.d == d)
  end

  if node.kind == "anniversary" then
    return node.m == m and node.d == d and (node.y == nil or y > node.y)
  end

  if node.kind == "cyclic" then
    local start = os.time({ year = node.y, month = node.m, day = node.d, hour = 12 })
    local target = iso_to_time(iso_date)
    if target < start then
      return false
    end
    local diff_days = math.floor((target - start) / 86400 + 0.5)
    return diff_days % node.n == 0
  end

  if node.kind == "block" then
    local lo = os.time({ year = node.y1, month = node.m1, day = node.d1, hour = 12 })
    local hi = os.time({ year = node.y2, month = node.m2, day = node.d2, hour = 12 })
    local t = iso_to_time(iso_date)
    return t >= lo and t <= hi
  end

  if node.kind == "float" then
    if node.month ~= "t" and node.month ~= m then
      return false
    end
    if dow(iso_date) ~= node.dayname then
      return false
    end
    if node.n > 0 then
      return nth_dow_in_month(iso_date) == node.n
    end
    -- Negative n: count from end (-1 = last DOW in month).
    if node.n == -1 then
      return is_last_dow_in_month(iso_date)
    end
    return false
  end

  return false
end

-- Scan a buffer for `<%%(...)>` diary sexps. Returns a list of:
--   { hl_line, sexp_text, parsed }
-- where hl_line is the 1-based line of the headline owning the sexp.
function M.scan(bufnr)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local owner_hl
  local out = {}
  for i, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      owner_hl = i
    end
    for sexp in ln:gmatch("<%%%%%b()>") do
      -- Lua's %b matches balanced parens, returning "(stuff)" — already wrapped
      -- so strip the surrounding `<%%` and `>` carefully. Easier: re-extract
      -- without the literal `<%%` prefix.
      local inner = sexp -- already in the form "<%%(...)>"
      local parsed = M.parse(inner)
      out[#out + 1] = { hl_line = owner_hl or i, sexp_text = inner, parsed = parsed }
    end
  end
  return out
end

-- Convenience: which headlines in `bufnr` have a sexp that fires on `iso_date`?
function M.matches_in_buffer(bufnr, iso_date)
  local out = {}
  for _, rec in ipairs(M.scan(bufnr)) do
    if rec.parsed and M.matches(rec.parsed, iso_date) then
      out[#out + 1] = rec
    end
  end
  return out
end

-- Agenda integration: scan every indexed .org file for diary sexps, evaluate
-- them across a date window, and produce synthetic agenda rows.
--
-- Returned rows match the shape of organ.query.agenda() rows minimally:
--   { file_path, line_start, title, todo_state, scheduled, scheduled_date,
--     synthetic = "diary_sexp" }
--
-- Pure function; the agenda module merges these with its own DB query results.

local function read_file_lines(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local body = fd:read("*a")
  fd:close()
  return vim.split(body, "\n", { plain = true })
end

-- Walk a list of file lines collecting { hl_line, hl_title, sexp_text, parsed }.
local function scan_lines(lines)
  local out = {}
  local hl_line, hl_title
  for i, ln in ipairs(lines) do
    local stars = ln:match("^(%*+)%s+(.*)$")
    if stars then
      hl_line = i
      hl_title = (ln:gsub("^%*+%s+", "")):gsub("^[A-Z][A-Z_]+%s+", ""):gsub("%s+:[%w_:@]+:%s*$", "")
    end
    for sexp in ln:gmatch("<%%%%%b()>") do
      local parsed = M.parse(sexp)
      out[#out + 1] = {
        hl_line = hl_line or i,
        hl_title = hl_title or "",
        sexp_text = sexp,
        parsed = parsed,
      }
    end
  end
  return out
end

-- Scan a single file, evaluate each sexp across the days in [from, to],
-- and emit one synthetic agenda row per (sexp, matching_day) pair.
local function file_to_agenda_rows(path, from_iso, to_iso)
  local lines = read_file_lines(path)
  if not lines then
    return {}
  end
  local recs = scan_lines(lines)
  if #recs == 0 then
    return {}
  end
  local out = {}
  -- Iterate days from..to.
  local function iso_t(iso)
    local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then
      return nil
    end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  end
  local from_t, to_t = iso_t(from_iso), iso_t(to_iso)
  if not from_t or not to_t then
    return {}
  end
  for t = from_t, to_t, 86400 do
    local day_iso = os.date("%Y-%m-%d", t)
    for _, rec in ipairs(recs) do
      if rec.parsed and M.matches(rec.parsed, day_iso) then
        out[#out + 1] = {
          file_path = path,
          line_start = rec.hl_line,
          title = rec.hl_title,
          todo_state = nil,
          scheduled = "<" .. day_iso .. ">",
          scheduled_date = day_iso,
          synthetic = "diary_sexp",
        }
      end
    end
  end
  return out
end

-- Public: run diary sexps over the indexed file list for the given range.
function M.agenda_rows(from_iso, to_iso)
  local out = {}
  local ok, query = pcall(require, "organ.query")
  if not ok then
    return out
  end
  local ok2, files = pcall(query.files)
  if not ok2 or type(files) ~= "table" then
    return out
  end
  for _, f in ipairs(files) do
    if f.file_path then
      local rows = file_to_agenda_rows(f.file_path, from_iso, to_iso)
      for _, r in ipairs(rows) do
        out[#out + 1] = r
      end
    end
  end
  return out
end

return M
