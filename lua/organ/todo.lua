-- TODO state machine + buffer mutation for organ.nvim.

local M = {}

local obuf = require("organ.buf")
-- Parse an Emacs `org-todo-keywords` entry into structured form.
-- Annotation grammar (matches `org-set-todo-keywords` in org.el):
--
--   "WORD"                        -- bare keyword
--   "WORD(KEY)"                   -- KEY is the fast-selection char
--   "WORD(KEY!)"                  -- log timestamp on transition INTO this state
--   "WORD(KEY@)"                  -- log timestamp + prompt for note on entry
--   "WORD(KEY/!)"                 -- log timestamp on transition OUT of this state
--   "WORD(KEY/@)"                 -- log + prompt for note on exit
--   "WORD(KEY!/!)" / "(KEY@/!)" / "(KEY!/@)" / "(KEY@/@)"  -- both
--   "WORD(@)"                     -- no key, only log policy
--
-- Returns `{ name, key, on_enter, on_exit }` where on_enter / on_exit
-- are one of `nil` / `"time"` / `"note"`.
local function parse_keyword(entry)
  if type(entry) ~= "string" then
    return { name = entry }
  end
  local name, paren = entry:match("^(.-)%(([^)]*)%)$")
  if not name or name == "" then
    return { name = entry }
  end
  -- Annotation grammar inside the parens:
  --   ([alnum])?              key
  --   (!|@)?                  on_enter log policy (no '/' prefix)
  --   (/[!@])?                on_exit log policy
  local meta = { name = name }
  local rest = paren
  -- Optional fast-selection key — first char if it's NOT a policy marker.
  local first = rest:sub(1, 1)
  if first ~= "" and first ~= "!" and first ~= "@" and first ~= "/" then
    meta.key = first
    rest = rest:sub(2)
  end
  -- on_enter policy.
  local enter = rest:match("^([!@])")
  if enter then
    meta.on_enter = enter == "@" and "note" or "time"
    rest = rest:sub(2)
  end
  -- on_exit policy.
  local exit = rest:match("^/([!@])")
  if exit then
    meta.on_exit = exit == "@" and "note" or "time"
  end
  return meta
end
M._parse_keyword = parse_keyword

-- Strip Emacs key-binding / log-policy annotations from a sequence
-- entry to recover just the bare keyword name.
local function strip_annotation(kw)
  return parse_keyword(kw).name or kw
end

-- Normalise the user's `todo` config into a list-of-sequences.  Two
-- legal shapes (matching Emacs's `org-todo-keywords`):
--
--   { "TODO", "|", "DONE" }                       -- single sequence
--   { { "TODO", "|", "DONE" },
--     { "BUG", "|", "FIXED" } }                   -- multiple sequences
--
-- A sequence is detected by checking if the first element is a string;
-- a list-of-lists has tables as elements.
local function normalise_sequences(input)
  if type(input) ~= "table" or #input == 0 then
    return {}
  end
  if type(input[1]) == "table" then
    local out = {}
    for _, seq in ipairs(input) do
      local stripped = {}
      for _, k in ipairs(seq) do
        stripped[#stripped + 1] = strip_annotation(k)
      end
      out[#out + 1] = stripped
    end
    return out
  end
  local stripped = {}
  for _, k in ipairs(input) do
    stripped[#stripped + 1] = strip_annotation(k)
  end
  return { stripped }
end
M._normalise_sequences = normalise_sequences

-- Split a sequence into { actives = [...], dones = [...] } at the `|` marker.
-- A sequence with no `|` puts everything into actives.
local function split_seq(sequence)
  local actives, dones = {}, {}
  local in_done = false
  for _, k in ipairs(sequence or {}) do
    if k == "|" then
      in_done = true
    elseif in_done then
      dones[#dones + 1] = k
    else
      actives[#actives + 1] = k
    end
  end
  return actives, dones
end

-- Find which sequence (if any) contains `state`.  Returns the sequence
-- list and `nil` if not found.  When `current` is nil, returns the
-- first sequence so cycling from no-state lands in sequence 1.
local function find_sequence(state, sequences)
  if #sequences == 0 then
    return nil
  end
  if state == nil then
    return sequences[1]
  end
  for _, seq in ipairs(sequences) do
    for _, k in ipairs(seq) do
      if k == state then
        return seq
      end
    end
  end
  return nil
end
M._find_sequence = find_sequence

-- Build a name -> { name, key, on_enter, on_exit } map from the
-- user's raw config (annotations preserved).  Used by the fast-
-- selection UI and the log-policy resolver below.
local function build_metadata(input)
  if type(input) ~= "table" or #input == 0 then
    return {}
  end
  local out = {}
  local consume
  consume = function(seq)
    for _, k in ipairs(seq) do
      if type(k) == "string" and k ~= "|" then
        local meta = parse_keyword(k)
        if meta.name then
          out[meta.name] = meta
        end
      end
    end
  end
  if type(input[1]) == "table" then
    for _, seq in ipairs(input) do
      consume(seq)
    end
  else
    consume(input)
  end
  return out
end
M._build_metadata = build_metadata

-- Scan the first ~200 lines of a buffer for `#+TODO:` /
-- `#+TYP_TODO:` / `#+SEQ_TODO:` directives.  Each directive defines
-- one sequence; multiple directives accumulate into a multi-sequence
-- config.  Returns a list-of-sequences (already normalised; pipe and
-- annotations preserved) or `nil` when no directives are found.
--
-- Mirrors Emacs's per-file `org-todo-keywords` override behavior.
function M.buffer_sequences(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local n = math.min(200, vim.api.nvim_buf_line_count(bufnr))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  local raw = {}
  for _, l in ipairs(lines) do
    local val = l:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.*)$")
      or l:match("^%s*#%+[Tt][Yy][Pp]_[Tt][Oo][Dd][Oo]:%s*(.*)$")
      or l:match("^%s*#%+[Ss][Ee][Qq]_[Tt][Oo][Dd][Oo]:%s*(.*)$")
    if val and val ~= "" then
      local seq = {}
      for tok in val:gmatch("%S+") do
        seq[#seq + 1] = tok
      end
      if #seq > 0 then
        raw[#raw + 1] = seq
      end
    end
  end
  if #raw == 0 then
    return nil
  end
  return M._normalise_sequences(raw)
end

-- Effective sequences for a given buffer.  Buffer-local `#+TODO:`
-- directives win over global config (matches Emacs); falls back to
-- `cfg.todo.sequences` / `cfg.todo.sequence` when no directives, then
-- to a sane default if nothing is configured.
function M.effective_sequences(bufnr)
  local buf = bufnr and M.buffer_sequences(bufnr)
  if buf then
    return buf
  end
  local cfg = (require("organ").config and require("organ.buf_config").read(nil, "todo")) or {}
  local raw = cfg.sequences or cfg.sequence
  if not raw or #raw == 0 then
    raw = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "|", "DONE", "CANCELLED" }
  end
  return M._normalise_sequences(raw)
end

-- Flat list of all bare keyword names from the user's config (any
-- shape: single, multi, with or without annotations).  Pipe markers
-- excluded.  Convenience for consumers that iterate keywords without
-- caring about active/done split or sequence boundaries.
function M.all_keywords(input)
  if input == nil then
    local cfg = (require("organ").config and require("organ.buf_config").read(nil, "todo")) or {}
    input = cfg.sequences or cfg.sequence or {}
  end
  local out = {}
  for _, seq in ipairs(M._normalise_sequences(input)) do
    for _, k in ipairs(seq) do
      if k ~= "|" then
        out[#out + 1] = k
      end
    end
  end
  return out
end

-- Resolve effective log policy for a state transition `from -> to`.
-- Three sources, in priority order (matches Emacs):
--   1. Explicit `cfg.todo.log_states[to]` overrides everything.
--   2. Annotation `to.on_enter` (`!` or `@` after the key).
--   3. Annotation `from.on_exit` (`/!` or `/@` after the key).
-- Returns `nil` / `"time"` / `"note"`.  Equal `from`/`to` yields nil
-- (no policy on a no-op transition).
local function resolve_log_policy(from_state, to_state, cfg)
  if not to_state or from_state == to_state then
    return nil
  end
  local explicit = (cfg.log_states or {})[to_state]
  if explicit ~= nil then
    if explicit == false then
      return nil
    end
    return explicit
  end
  local meta = build_metadata(cfg.sequences or cfg.sequence or {})
  local to_meta = meta[to_state]
  if to_meta and to_meta.on_enter then
    return to_meta.on_enter
  end
  local from_meta = meta[from_state]
  if from_meta and from_meta.on_exit then
    return from_meta.on_exit
  end
  return nil
end
M._resolve_log_policy = resolve_log_policy

local function index_of(list, item)
  for i, v in ipairs(list) do
    if v == item then
      return i
    end
  end
  return nil
end

-- `sequence_or_sequences` accepts either a flat list (single sequence)
-- or a list-of-lists (multi-sequence per Emacs `org-todo-keywords`).
-- When the current keyword belongs to a specific sub-sequence,
-- cycling stays within it.
function M._compute_next_state(current, sequence_or_sequences)
  local sequences = normalise_sequences(sequence_or_sequences)
  local seq = find_sequence(current, sequences) or sequences[1] or {}
  local actives, dones = split_seq(seq)

  if current == nil then
    return actives[1] or dones[1] or nil
  end

  local ai = index_of(actives, current)
  if ai then
    if ai < #actives then
      return actives[ai + 1]
    end
    return dones[1] or nil
  end

  local di = index_of(dones, current)
  if di then
    if di < #dones then
      return dones[di + 1]
    end
    return nil
  end

  -- unknown current keyword → recover to first active (or first done)
  return actives[1] or dones[1] or nil
end

function M._compute_prev_state(current, sequence_or_sequences)
  local sequences = normalise_sequences(sequence_or_sequences)
  local seq = find_sequence(current, sequences) or sequences[1] or {}
  local actives, dones = split_seq(seq)
  if current == nil then
    return dones[#dones] or actives[#actives] or nil
  end
  local di = index_of(dones, current)
  if di then
    if di > 1 then
      return dones[di - 1]
    end
    return actives[#actives] or nil
  end
  local ai = index_of(actives, current)
  if ai then
    if ai > 1 then
      return actives[ai - 1]
    end
    return nil
  end
  return actives[#actives] or dones[#dones] or nil
end

-- Walk up to the headline that owns `line` (1-based).
local function find_headline(buf_lines, line)
  local hl = line
  while hl >= 1 and not buf_lines[hl]:match("^%*+%s") do
    hl = hl - 1
  end
  if hl < 1 then
    return nil
  end
  return hl
end

-- Match a headline line into its parts.
-- Returns: stars, todo_or_nil, rest (priority + title + tags).
local function split_headline(line, sequence_or_sequences)
  local stars, body = line:match("^(%*+)%s+(.*)$")
  if not stars then
    return nil
  end
  local sequences = normalise_sequences(sequence_or_sequences)
  -- The first whitespace-separated token is the keyword IFF it's in
  -- ANY of the configured sequences (Emacs treats all keywords across
  -- all sequences as the same recognition set).
  local first, rest = body:match("^(%S+)%s*(.*)$")
  if first then
    for _, seq in ipairs(sequences) do
      for _, k in ipairs(seq) do
        if k == first then
          return stars, first, rest
        end
      end
    end
  end
  return stars, nil, body
end

local function rebuild_headline(stars, todo, rest)
  if todo then
    return stars .. " " .. todo .. (rest == "" and "" or " " .. rest)
  else
    return stars .. (rest == "" and "" or " " .. rest)
  end
end

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return require("organ.buf_config").read(nil, "todo") or {}
end

local function default_sequence()
  return get_config().sequence
    or { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "|", "DONE", "CANCELLED" }
end

-- Multi-sequence aware: union of actives across every configured
-- sub-sequence.  An entry's classification is its position relative
-- to its OWN sequence's `|` marker.
local function active_set(sequence_or_sequences)
  local s = {}
  for _, seq in ipairs(normalise_sequences(sequence_or_sequences)) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif not in_done then
        s[k] = true
      end
    end
  end
  return s
end

local function done_set(sequence_or_sequences)
  local s = {}
  for _, seq in ipairs(normalise_sequences(sequence_or_sequences)) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif in_done then
        s[k] = true
      end
    end
  end
  return s
end

local function is_done(state, sequence)
  return state ~= nil and done_set(sequence)[state] == true
end

local function is_active(state, sequence)
  return state ~= nil and active_set(sequence)[state] == true
end

local function now_inactive_ts()
  local t = os.date("*t")
  local DOW = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
  local dow = DOW[tonumber(os.date("%w", os.time(t)))]
  return string.format("[%04d-%02d-%02d %s %02d:%02d]", t.year, t.month, t.day, dow, t.hour, t.min)
end

-- Returns 1-based line indices: { closed = N | nil, planning_end = N }
-- where planning_end is the line index of the LAST planning line (SCHEDULED/DEADLINE/CLOSED)
-- under the given headline, or hl_line itself if no planning lines exist.
local function find_planning_block(buf_lines, hl_line)
  -- Walks the headline's section.  Skips drawer ranges and blank lines so
  -- the org-habit-style layout (property drawer before SCHEDULED) still
  -- finds planning lines correctly.
  local closed_idx = nil
  local last_planning = hl_line
  local i = hl_line + 1
  while i <= #buf_lines do
    local ln = buf_lines[i]
    if ln:match("^%*+%s") then
      break
    end
    -- Planning keywords are case-insensitive in Emacs (case-fold-search
    -- on org-keyword-time-regexp).
    if
      ln:match("^%s*[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:")
      or ln:match("^%s*[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:")
      or ln:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:")
    then
      if ln:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:") then
        closed_idx = i
      end
      last_planning = i
      i = i + 1
    elseif ln:match("^%s*:[%w_]+:%s*$") then
      i = i + 1
      while i <= #buf_lines and not buf_lines[i]:match("^%s*:END:%s*$") do
        if buf_lines[i]:match("^%*+%s") then
          break
        end
        i = i + 1
      end
      i = i + 1 -- past :END:
    elseif ln:match("^%s*$") then
      i = i + 1
    else
      break
    end
  end
  return { closed = closed_idx, planning_end = last_planning }
end

local function set_property(bufnr, hl_line, key, value)
  local element = require("organ.element")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pd = element.property_drawer_range(bufnr, hl_line - 1)
  local prop_line = string.format("  :%s: %s", key, value)
  if pd then
    -- Replace existing key in drawer if present.
    for i = pd.start_line + 1, pd.end_line - 1 do
      if (lines[i] or ""):match("^%s*:" .. key .. ":") then
        obuf.set_lines(bufnr, i - 1, i, { prop_line })
        return
      end
    end
    -- Append before :END:.
    obuf.set_lines(bufnr, pd.end_line - 1, pd.end_line - 1, { prop_line })
  else
    -- Create a new drawer right after planning.
    local i = element.planning_end_line(bufnr, hl_line - 1)
    obuf.set_lines(bufnr, i - 1, i - 1, { "  :PROPERTIES:", prop_line, "  :END:" })
  end
end

-- Find SCHEDULED / DEADLINE lines under hl_line. Returns
--   { scheduled = idx | nil, deadline = idx | nil }
--
-- Walks every line of the headline's section (until the next `* ` headline
-- or end of buffer), skipping over drawer ranges (`:NAME:` … `:END:`)
-- and stopping early only when content that's clearly outside planning
-- begins (a non-whitespace, non-drawer, non-planning line).  This handles
-- common org layouts where planning sits AFTER a property drawer (the
-- layout `org-habit` recommends).
local function find_planning_lines(buf_lines, hl_line, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pl = require("organ.element").planning_lines(bufnr, hl_line - 1)
  -- TS path returns scheduled/deadline (closed not used by callers here).
  if pl.scheduled or pl.deadline then
    return pl
  end
  -- Regex fallback for parser-not-loaded scratch buffers.
  local out = {}
  local i = hl_line + 1
  while i <= #buf_lines do
    local ln = buf_lines[i]
    if ln:match("^%*+%s") then
      break
    end
    if ln:match("^%s*[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:") then
      out.scheduled = i
      i = i + 1
    elseif ln:match("^%s*[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:") then
      out.deadline = i
      i = i + 1
    elseif ln:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:") then
      i = i + 1
    elseif ln:match("^%s*:[%w_%-]+:%s*$") then
      i = i + 1
      while i <= #buf_lines and not buf_lines[i]:match("^%s*:[Ee][Nn][Dd]:%s*$") do
        if buf_lines[i]:match("^%*+%s") then
          break
        end
        i = i + 1
      end
      i = i + 1
    elseif ln:match("^%s*$") then
      i = i + 1
    else
      break
    end
  end
  return out
end

-- Try to bump SCHEDULED/DEADLINE timestamps if they have repeaters. Returns
-- true if any bump happened (and the state transition should be cancelled).
local function try_bump_repeaters(bufnr, hl_line, now_yyyy_mm_dd)
  local rep = require("organ.todo.repeater")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pl = find_planning_lines(lines, hl_line, bufnr)
  local bumped = false

  for _, key in ipairs({ "scheduled", "deadline" }) do
    local idx = pl[key]
    if idx then
      local ln = lines[idx]
      -- Extract the timestamp (between < > or [ ]).
      local ts = ln:match("(<[^>]+>)") or ln:match("(%b[])")
      if ts and rep.parse(ts) then
        local new_ts, err = rep.bump(ts, now_yyyy_mm_dd)
        if new_ts then
          local new_line = ln:gsub(vim.pesc(ts), new_ts, 1)
          obuf.set_lines(bufnr, idx - 1, idx, { new_line })
          bumped = true
        elseif err then
          require("organ.notify").warn(err)
        end
      end
    end
  end

  return bumped
end

local drawer = require("organ.drawer")
local function find_drawer(buf_lines, hl_line, drawer_name, bufnr)
  return drawer.find(buf_lines, hl_line, drawer_name, bufnr)
end
local function drawer_insert_position(buf_lines, hl_line, bufnr)
  return drawer.insert_position(buf_lines, hl_line, bufnr)
end

local function build_logbook_entry(from_state, to_state, note)
  local ts = now_inactive_ts()
  local first_line = string.format(
    '- State "%s"       from "%s"       %s \\\\',
    to_state or "(none)",
    from_state or "(none)",
    ts
  )
  if note and note ~= "" then
    return { first_line, "  " .. note }
  end
  return { first_line }
end

-- Prepend a LOGBOOK entry. Creates the drawer if absent.
local function add_logbook_entry(bufnr, hl_line, drawer_name, from_state, to_state, note)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entry = build_logbook_entry(from_state, to_state, note)
  local start_idx, end_idx = find_drawer(lines, hl_line, drawer_name, bufnr)
  if start_idx then
    -- Insert entry just after the :DRAWER: line (newest first).
    obuf.set_lines(bufnr, start_idx, start_idx, entry)
  else
    -- Create a new drawer.
    local pos = drawer_insert_position(lines, hl_line, bufnr)
    local block = { ":" .. drawer_name .. ":" }
    for _, l in ipairs(entry) do
      block[#block + 1] = l
    end
    block[#block + 1] = ":END:"
    obuf.set_lines(bufnr, pos - 1, pos - 1, block)
  end
end

-- Insert a state-change entry as bare list items (no drawer wrapper).
-- Mirrors Emacs `org-log-into-drawer = nil`: the entry sits at the head of
-- the section, after planning + property drawer.
local function add_logbook_entry_bare(bufnr, hl_line, from_state, to_state, note)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entry = build_logbook_entry(from_state, to_state, note)
  local pos = drawer_insert_position(lines, hl_line, bufnr)
  obuf.set_lines(bufnr, pos - 1, pos - 1, entry)
end

-- Resolve which LOGBOOK policy applies to this transition.
-- Returns nil | "time" | "note".
--
-- Priority order (matches Emacs `org-log-note-headings` resolution):
--   1. Explicit per-destination override (`cfg.log_states[new_state]`).
--      Setting to `false` suppresses logging.
--   2. Annotation `new_state.on_enter` (e.g. `"NEXT(n!)"` -> "time" on
--      transition INTO NEXT) and `current.on_exit` (e.g. `"DONE(d/!)"`
--      -> "time" when transitioning AWAY from DONE).
--   3. `cfg.log_done = "note"` legacy active->done shortcut.
--   4. `cfg.log_state_changes = true` blanket "log every transition".
local function resolve_logbook_policy(cfg, current, new_state, sequence)
  if current == new_state then
    return nil
  end
  if not new_state then
    return nil
  end

  local per_state = (cfg.log_states or {})[new_state]
  if per_state == false then
    return nil
  end
  if per_state == "time" or per_state == "note" then
    return per_state
  end

  -- Annotation-derived policy.  Resolves both `new.on_enter` and
  -- `current.on_exit` at once (annotation parser already prioritises
  -- on_enter over on_exit) so a user's `(sequence "TODO(t)" "WAIT(w@)"
  -- "|" "DONE(d!)")` produces a note on entering WAIT and a timestamp
  -- on entering DONE without separate config.
  local annotated = resolve_log_policy(current, new_state, cfg)
  if annotated then
    return annotated
  end

  local was_active = is_active(current, sequence) or current == nil
  local new_done = is_done(new_state, sequence)
  if was_active and new_done and cfg.log_done == "note" then
    return "note"
  end

  if cfg.log_state_changes then
    return "time"
  end
  return nil
end

-- Write a state-change LOGBOOK entry obeying cfg.log_into_drawer.
local function write_logbook(bufnr, hl_line, cfg, from_state, to_state, note)
  local drawer_name = cfg.log_drawer or "LOGBOOK"
  if cfg.log_into_drawer == false then
    add_logbook_entry_bare(bufnr, hl_line, from_state, to_state, note)
  else
    add_logbook_entry(bufnr, hl_line, drawer_name, from_state, to_state, note)
  end
end

local function insert_closed_line(bufnr, hl_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = find_planning_block(lines, hl_line)
  local new = "  CLOSED: " .. now_inactive_ts()
  if block.closed then
    -- Replace existing CLOSED line in place.
    obuf.set_lines(bufnr, block.closed - 1, block.closed, { new })
  else
    -- Insert after the last planning line.
    obuf.set_lines(bufnr, block.planning_end, block.planning_end, { new })
  end
end

local function remove_closed_line(bufnr, hl_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = find_planning_block(lines, hl_line)
  if block.closed then
    obuf.set_lines(bufnr, block.closed - 1, block.closed, {})
  end
end

-- Apply a state change to a buffer at the headline owning `line`. Performs the
-- side effects (CLOSED line, LOGBOOK note, repeater bump, LAST_REPEAT property)
-- per config.todo.log_done. Returns nil on success, error string otherwise.
--
-- Exposed for tests: side-effect tasks (Tasks 7-9) extend this function.
function M._apply(bufnr, line, new_state)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "source buffer no longer valid"
  end
  if vim.bo[bufnr].modifiable == false then
    return "buffer is not modifiable"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hl = find_headline(lines, line)
  if not hl then
    return "no headline at or above cursor"
  end

  local sequence = M.effective_sequences(bufnr)
  local stars, current, rest = split_headline(lines[hl], sequence)
  if not stars then
    return "no headline at or above cursor"
  end

  local cfg = get_config()
  local was_active = is_active(current, sequence)
  local was_done = is_done(current, sequence)
  local new_done = is_done(new_state, sequence)
  local new_active = is_active(new_state, sequence)

  -- Dependency guards (ORDERED, parent-blocked-by-children, checkbox).
  -- Only block transitions to a DONE state.
  if new_done then
    local blocked = require("organ.dependencies").check(bufnr, hl, new_state, sequence)
    if blocked then
      return blocked
    end
  end

  -- Repeating-task bump: on active→done, if SCHEDULED/DEADLINE has a repeater,
  -- bump the date and KEEP the active state. CLOSED line is NOT added.
  local now = (M._now_for_test and M._now_for_test()) or os.date("%Y-%m-%d")
  if (was_active or current == nil) and new_done then
    if try_bump_repeaters(bufnr, hl, now) then
      -- Stamp LAST_REPEAT: [<now>] property.
      set_property(bufnr, hl, "LAST_REPEAT", now_inactive_ts())
      -- Save and exit early; don't transition state, don't insert CLOSED.
      local cur = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_current_buf(bufnr)
      vim.cmd("silent! write")
      vim.api.nvim_set_current_buf(cur)
      return nil
    end
  end

  -- Rewrite the headline line first so subsequent line indices stay valid for
  -- the planning block (which sits below the headline).
  local new_line = rebuild_headline(stars, new_state, rest)
  obuf.set_lines(bufnr, hl - 1, hl, { new_line })

  -- CLOSED bookkeeping.
  if cfg.log_done == "time" or cfg.log_done == "note" then
    if (was_active or current == nil) and new_done then
      insert_closed_line(bufnr, hl)
    elseif was_done and (new_active or new_state == nil) then
      remove_closed_line(bufnr, hl)
    end
  end

  -- LOGBOOK state-change entry. Covers active→done note (legacy log_done = "note"),
  -- per-destination-state policy (log_states), and blanket logging
  -- (log_state_changes). Time-only entries are written synchronously; note
  -- entries prompt via vim.ui.input (synchronous in tests via mock).
  local policy = resolve_logbook_policy(cfg, current, new_state, sequence)
  if policy == "time" then
    write_logbook(bufnr, hl, cfg, current, new_state, nil)
  elseif policy == "note" then
    local prompt = string.format("State change note (%s): ", new_state or "(none)")
    vim.ui.input({ prompt = prompt }, function(note)
      if note and note ~= "" then
        write_logbook(bufnr, hl, cfg, current, new_state, note)
        local cur2 = vim.api.nvim_get_current_buf()
        vim.api.nvim_set_current_buf(bufnr)
        vim.cmd("silent! write")
        vim.api.nvim_set_current_buf(cur2)
      end
    end)
  end

  -- Statistics cookies on ancestor headlines reflect this transition.
  pcall(function()
    require("organ.statistics").update_ancestors(bufnr, hl)
  end)

  -- Auto clock-out on transition into a done-type state (mirror
  -- Emacs `org-clock-out-when-done`).  Only fires when this exact
  -- headline is the active clock target — clocking on a different
  -- headline is left alone.  Default true; set
  -- `clock.out_when_done = false` to keep clocks running across
  -- DONE transitions.
  if was_active and new_done then
    local clock_cfg = (require("organ.buf_config").read(nil, "clock") or {})
    if clock_cfg.out_when_done ~= false then
      pcall(function()
        local clock = require("organ.clock")
        local s = clock.status and clock.status()
        if s then
          local file = vim.api.nvim_buf_get_name(bufnr)
          local on_this = (s.file_path == file or (s.active and s.active.file_path == file))
          local s_line = s.line_start or (s.active and s.active.line_start)
          if on_this and s_line == hl - 1 then
            clock.stop()
          end
        end
      end)
    end
  end

  -- Save synchronously so BufWritePost reindexes.
  local cur = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  vim.cmd("silent! write")
  vim.api.nvim_set_current_buf(cur)

  return nil
end

function M.cycle(bufnr, line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "source buffer no longer valid"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hl = find_headline(lines, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local sequence = M.effective_sequences(bufnr)
  local _, current = split_headline(lines[hl], sequence)
  local next_state = M._compute_next_state(current, sequence)
  return M._apply(bufnr, line, next_state)
end

function M.cycle_back(bufnr, line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "source buffer no longer valid"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hl = find_headline(lines, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local sequence = M.effective_sequences(bufnr)
  local _, current = split_headline(lines[hl], sequence)
  local prev_state = M._compute_prev_state(current, sequence)
  return M._apply(bufnr, line, prev_state)
end

function M.set(bufnr, line, state)
  return M._apply(bufnr, line, state)
end

-- Exported for sibling modules + tests.
M._is_done = is_done
M._is_active = is_active
M._find_headline = find_headline
M._split_headline = split_headline
M._rebuild_headline = rebuild_headline
M._default_sequence = default_sequence

local function complete_states()
  local out = { "none" }
  for _, k in ipairs(M.all_keywords()) do
    out[#out + 1] = k
  end
  return out
end

-- Fast-selection UI.  Mirrors Emacs `org-fast-todo-selection`
-- (the one-char prompt opened by `C-c C-t` when org-use-fast-todo-
-- selection is non-nil).  Shows every keyword that has a `(KEY)`
-- annotation, the user types the key, and that state is applied.
-- Pressing `<Space>` clears the state; `<Esc>` cancels.
local function fast_select(bufnr, line)
  -- Effective config: file-level `#+TODO:` overrides global config.
  -- We need raw input (with annotations) to resolve fast-keys, so
  -- re-scan the buffer for `#+TODO:` lines here directly rather than
  -- using the already-stripped output of `effective_sequences`.
  local function buffer_raw_sequences()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local n = math.min(200, vim.api.nvim_buf_line_count(bufnr))
    local lines_local = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
    local raw = {}
    for _, l in ipairs(lines_local) do
      local val = l:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.*)$")
        or l:match("^%s*#%+[Tt][Yy][Pp]_[Tt][Oo][Dd][Oo]:%s*(.*)$")
        or l:match("^%s*#%+[Ss][Ee][Qq]_[Tt][Oo][Dd][Oo]:%s*(.*)$")
      if val and val ~= "" then
        local seq = {}
        for tok in val:gmatch("%S+") do
          seq[#seq + 1] = tok
        end
        if #seq > 0 then
          raw[#raw + 1] = seq
        end
      end
    end
    if #raw == 0 then
      return nil
    end
    return raw
  end
  local cfg = (require("organ.buf_config").read(nil, "todo") or {})
  local raw = buffer_raw_sequences() or cfg.sequences or cfg.sequence or {}
  local meta = M._build_metadata(raw)
  -- Preserve config order when listing.
  local entries = {}
  local function add_seq(seq)
    for _, k in ipairs(seq) do
      if k ~= "|" then
        local bare = M._parse_keyword(k).name
        local m = bare and meta[bare]
        if m and m.key then
          entries[#entries + 1] = m
        end
      end
    end
  end
  if type(raw[1]) == "table" then
    for _, seq in ipairs(raw) do
      add_seq(seq)
    end
  else
    add_seq(raw)
  end
  if #entries == 0 then
    -- No fast-selection keys configured -- fall back to vim.ui.select
    -- so the keymap still does something reasonable.  Tell the user
    -- inline how to enable the proper one-char prompt.
    local choices = { "(none)" }
    for _, k in ipairs(M.all_keywords()) do
      choices[#choices + 1] = k
    end
    vim.ui.select(choices, {
      prompt = 'TODO state (annotate `"TODO(t)"` for fast keys):',
    }, function(choice)
      if not choice then
        return
      end
      M.set(bufnr, line, choice == "(none)" and nil or choice)
    end)
    return
  end
  -- Render `[t] TODO   [w] WAIT   [d] DONE` on a single status line.
  -- Long sequences wrap.  Highlights via echo for now (no float to
  -- keep this lightweight; matches Emacs's echo-area prompt style).
  local pieces = {}
  for _, m in ipairs(entries) do
    pieces[#pieces + 1] = string.format("[%s] %s", m.key, m.name)
  end
  vim.api.nvim_echo({
    { "Set TODO: ", "Question" },
    { table.concat(pieces, "  "), "Normal" },
    { "  (<Space>=clear, <Esc>=cancel)", "Comment" },
  }, false, {})
  local code = vim.fn.getcharstr()
  vim.api.nvim_echo({ { "" } }, false, {})
  if code == "" or code == "\27" then -- <Esc>
    return
  end
  if code == " " then
    return M.set(bufnr, line, nil)
  end
  for _, m in ipairs(entries) do
    if m.key == code then
      return M.set(bufnr, line, m.name)
    end
  end
  require("organ.notify").error(string.format("no TODO keyword bound to '%s'", code))
end
M._fast_select = fast_select

M.commands = {
  todo = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local args = cmd and cmd.args or ""
      local err
      if args == "" then
        err = M.cycle(bufnr, line)
      elseif args:lower() == "none" then
        err = M.set(bufnr, line, nil)
      else
        err = M.set(bufnr, line, args)
      end
      if err then
        require("organ.notify").error(err)
      end
    end,
    nargs = "?",
    complete = complete_states,
    desc = "Cycle (no arg) or set the TODO state of the headline at cursor",
  },
  ["todo fast"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      fast_select(bufnr, line)
    end,
    desc = "Pick a TODO keyword by single-char selection key (Emacs C-c C-t)",
  },
}

return M
