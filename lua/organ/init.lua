-- organ.nvim entrypoint.
--
-- setup(opts) is intentionally cheap: it merges config, initialises the
-- two-tier write queue, and wires autocmds. Heavy resources (SQLite DB,
-- tree-sitter parser) are opened lazily on first use via organ.runtime.
-- All writes funnel through the queue so the DB is never contended.

local db = require("organ.db")
local indexer = require("organ.indexer")
local queue = require("organ.queue")
local events = require("organ.events")

local M = {}

M.config = require("organ.defaults")

M._db = nil
M._last_status = { last_file = nil, last_ts = nil, errors = {} }
M._scan =
  { in_flight = false, ok_count = 0, err_snapshot = 0, indexed_files = 0, indexed_headlines = 0 }
-- Largest single main-thread slice the cooperative indexer has held, and
-- how many slices it has run. Observability for "indexing never blocks";
-- the async-indexer regression test asserts max_slice_ms stays bounded.
M._index_stats = { max_slice_ms = 0, slices = 0 }
M._compat_listeners = {} -- { {event, fn}, ... } listeners registered by back-compat shims

local function notify(msg, level)
  if not M.config.notify then
    return
  end
  require("organ.errors").schedule("organ.init", function()
    require("organ.notify").notify(level or vim.log.levels.INFO, msg)
  end)
end

local function notify_debug(msg)
  if not M.config.notify then
    return
  end
  require("organ.errors").schedule("organ.init", function()
    require("organ.notify").debug(msg)
  end)
end

local function record_error(err)
  table.insert(M._last_status.errors, 1, { ts = os.time(), err = err })
  if #M._last_status.errors > 5 then
    M._last_status.errors[6] = nil
  end
  if M.config.on_error then
    pcall(M.config.on_error, err)
  end
end

-- v1 is the initial public-release baseline. A schema change ships as
-- four edits that tests/db_migration_test.lua holds together:
--   1. sql/schema.sql        -- the fresh-install shape
--   2. SCHEMA_VERSION        -- bump by one
--   3. MIGRATIONS[<new>]     -- upgrade a live index one step
--   4. tests/fixtures/schema/v<new>.sql -- snapshot of the new schema.sql
local SCHEMA_VERSION = 1

-- MIGRATIONS[n] upgrades a live DB from user_version n-1 to n. Each step
-- runs inside a transaction and must leave the schema identical to a
-- fresh schema.sql install at version n (the migration test asserts
-- this equivalence).
local MIGRATIONS = {}

-- Columns that MUST exist on each table for the current build's queries
-- to compile. ensure_schema verifies them after the version checks as a
-- sanity net: a DB that reports the current user_version but lacks one
-- of these predates the versioned-schema baseline, and ensure_schema
-- errors with a recovery message instead of touching the data.
--
-- Add to this list whenever schema.sql gains a new column the queries
-- depend on.
local REQUIRED_COLUMNS = {
  files = { "extractor_version" },
  headlines = { "commented" },
  file_todo_keywords = { "is_done" },
  state_changes = { "to_state" },
}

-- Returns true when every column in REQUIRED_COLUMNS exists on its
-- table.  False when one is missing (the DB was created against an
-- older schema and predates a column the current build's queries
-- reference).
local function db_columns_match(h)
  for table_name, cols in pairs(REQUIRED_COLUMNS) do
    local present = {}
    local stmt, perr = h:prepare("PRAGMA table_info(" .. table_name .. ")")
    if not stmt then
      -- Table itself missing → schema definitely stale.
      pcall(function()
        local _ = perr
      end)
      return false
    end
    while stmt:step() == db.SQLITE_ROW do
      present[stmt:column_text(1)] = true -- column 1 = name
    end
    stmt:finalize()
    for _, c in ipairs(cols) do
      if not present[c] then
        return false, table_name, c
      end
    end
  end
  return true
end

-- Cascade a live DB from user_version from_v to to_v, one transactional
-- step at a time. Each step applies migrations[v] and stamps
-- PRAGMA user_version = v inside the same transaction, so a failed step
-- leaves the index byte-for-byte untouched. A missing step is an error:
-- organ never drops or rebuilds the index to paper over a gap.
local function run_migrations(h, from_v, to_v, migrations)
  if from_v < to_v then
    notify(("organ: upgrading index schema v%d -> v%d"):format(from_v, to_v))
  end
  for v = from_v + 1, to_v do
    if type(migrations[v]) ~= "function" then
      error(
        (
          "organ: no migration from index schema v%d to v%d for db %s. "
          .. "organ will not touch the index; downgrade organ.nvim or wait "
          .. "for a build that ships this migration."
        ):format(v - 1, v, M.config.db_path or "<unknown>")
      )
    end
    local terr = h:transaction(function(th)
      migrations[v](th)
      assert(th:exec("PRAGMA user_version = " .. v))
    end)
    if terr then
      error(
        ("organ: migration to schema v%d failed (index unchanged) for db %s: %s"):format(
          v,
          M.config.db_path or "<unknown>",
          terr
        )
      )
    end
  end
end

-- Apply schema idempotently.
--   user_version == 0         -> fresh DB, apply schema.sql + stamp
--   user_version == VERSION   -> already current, no-op
--   user_version >  VERSION   -> DB created by a newer organ; refuse so
--                                we don't silently downgrade
--   user_version <  VERSION   -> cascade MIGRATIONS, one transactional
--                                step per version
--
-- Last, verifies REQUIRED_COLUMNS exist. A missing column means the DB
-- predates the versioned-schema baseline; ensure_schema errors with the
-- recovery (delete the db file, re-scan) and never modifies the index.
--
-- Exposed as M._ensure_schema(h) so lua/organ/runtime.lua can call it
-- without a circular require (runtime -> organ -> runtime).
local function ensure_schema(h)
  local s = assert(h:prepare("PRAGMA user_version"))
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()

  if v == 0 then
    local sql = table.concat(vim.fn.readfile(M.config.schema_path), "\n")
    local ok, err = h:exec(sql)
    if not ok then
      error("organ: schema apply failed: " .. tostring(err))
    end
    pcall(function()
      h:exec("PRAGMA user_version = " .. SCHEMA_VERSION)
    end)
    return
  end

  if v > SCHEMA_VERSION then
    error(
      (
        "organ: db schema version %d is newer than this build expects (%d). "
        .. "Refusing to downgrade. Either upgrade organ.nvim or delete the db: %s"
      ):format(v, SCHEMA_VERSION, M.config.db_path or "<unknown>")
    )
  end

  if v < SCHEMA_VERSION then
    run_migrations(h, v, SCHEMA_VERSION, MIGRATIONS)
  end

  local cols_ok, missing_table, missing_col = db_columns_match(h)
  if not cols_ok then
    error(
      (
        "organ: index schema is missing `%s.%s` -- this db predates the "
        .. "versioned-schema baseline (pre-release build). Delete the file "
        .. "at %s and restart; the next `:Org scan` rebuilds the index "
        .. "from your org files."
      ):format(
        tostring(missing_table),
        tostring(missing_col),
        M.config.db_path or "<unknown>"
      )
    )
  end
end

-- Expose ensure_schema publicly so runtime.lua can call it without re-opening
-- the DB. Defined here (after the local) so the upvalue is valid.
-- _run_migrations and _migrations are test seams: tests/db_migration_test.lua
-- drives the cascade with injected migration tables and asserts ledger
-- continuity against the real one.
function M._ensure_schema(h)
  return ensure_schema(h)
end

function M._run_migrations(h, from_v, to_v, migrations)
  return run_migrations(h, from_v, to_v, migrations)
end

M._migrations = MIGRATIONS

-- Read file contents with a bounded stat (mtime) so the skip path is cheap.
local function read_file(path)
  local st = vim.loop.fs_stat(path)
  if not st then
    return nil, nil, "stat failed: " .. path
  end
  local f = io.open(path, "r")
  if not f then
    return nil, nil, "open failed: " .. path
  end
  local src = f:read("*a")
  f:close()
  return src, st.mtime.sec, nil
end

-- Drop DB rows for files that the just-completed `scan_walk` did
-- NOT visit (i.e. files that vanished from disk while organ wasn't
-- watching — watcher disabled, force-quit, edits on another
-- machine).  Cascades through file_tags / headlines /
-- file_todo_keywords via the schema's `ON DELETE CASCADE`.
--
-- Cheap: `M._scan.visited` is the set scan_walk just enumerated, so
-- no per-file fs_stat is needed.  One SELECT + one DELETE per stale
-- row.  Bounded by the number of files actually missing.
local function prune_orphans_from_visited(root, visited)
  local rt = require("organ.runtime")
  local h = rt.db_if_open()
  if not h then
    return 0
  end
  local s, perr = h:prepare("SELECT path FROM files WHERE path LIKE ?")
  if not s then
    return 0, perr
  end
  s:bind_text(1, root .. "%")
  local db = require("organ.db")
  local stale = {}
  while s:step() == db.SQLITE_ROW do
    local p = s:column_text(0)
    if p and not visited[p] then
      stale[#stale + 1] = p
    end
  end
  s:finalize()
  for _, p in ipairs(stale) do
    pcall(indexer.forget, h, p)
  end
  return #stale
end

local function fire_scan_done()
  if not M._scan.in_flight then
    return
  end
  M._scan.in_flight = false
  local pruned = 0
  if M._scan.visited then
    pruned = prune_orphans_from_visited(M.config.org_dir, M._scan.visited) or 0
    M._scan.visited = nil
  end
  if pruned > 0 then
    notify(string.format("pruned %d orphan file(s) from index", pruned))
  end
  local n_files = M._scan.indexed_files
  if n_files > 0 then
    notify(
      string.format("indexed %d headline(s) across %d file(s)", M._scan.indexed_headlines, n_files)
    )
  end
  local errs = {}
  for i = M._scan.err_snapshot + 1, #M._last_status.errors do
    errs[#errs + 1] = M._last_status.errors[i]
  end
  events.emit("scan_done", { n_ok = M._scan.ok_count, errors = errs })
end

local function start_scan()
  M._scan.in_flight = true
  M._scan.ok_count = 0
  M._scan.indexed_files = 0
  M._scan.indexed_headlines = 0
  M._scan.err_snapshot = #M._last_status.errors
end

-- Polls queue.is_empty after a scan_walk completes; fires on_scan_done once.
local function poll_scan_completion()
  local t = vim.loop.new_timer()
  t:start(
    100,
    100,
    vim.schedule_wrap(function()
      -- Defensive: another path may have already closed this timer (e.g.
      -- a fresh scan started before the old one drained). Treat any post-
      -- close fire as a no-op.
      if t:is_closing() then
        return
      end
      if queue.is_empty() then
        t:stop()
        t:close()
        fire_scan_done()
      end
    end)
  )
end

-- Cooperative per-file indexer body. Runs inside a coroutine (see
-- index_async) so it can yield: a thunk `function(resume)` for an
-- off-main-thread step (async parse), or "slice" to resume next tick.
-- Raises on read/write failure; index_async records it.
local function index_body(op, tier)
  local path = op.path
  local h = require("organ.runtime").db()

  if op.kind == "delete" then
    local derr = h:transaction(function()
      indexer.forget_body(h, path)
    end)
    if derr then
      record_error("delete " .. path .. ": " .. tostring(derr))
    end
    events.emit("indexed", { path = path, deleted = true })
    return
  end

  local bufnr
  if M.config.incremental then
    local b = vim.fn.bufnr(path)
    if b > 0 and vim.api.nvim_buf_is_loaded(b) then
      bufnr = b
    end
  end

  local mtime
  if M.config.mtime_skip then
    local st = vim.loop.fs_stat(path)
    if st then
      mtime = st.mtime.sec
      if indexer.should_skip(h, path, mtime, nil) == "mtime" then
        if tier == "background" and M._scan.in_flight then
          M._scan.ok_count = M._scan.ok_count + 1
        end
        events.emit("indexed", { path = path, skipped = "mtime" })
        return
      end
    end
  end

  local src
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    src = table.concat(lines, "\n") .. "\n"
  else
    local s, mt, err = read_file(path)
    if err then
      error(err)
    end
    src = s
    mtime = mtime or mt
  end

  local hash = vim.fn.sha256(src)
  if M.config.hash_skip and indexer.should_skip(h, path, nil, hash) == "hash" then
    if tier == "background" and M._scan.in_flight then
      M._scan.ok_count = M._scan.ok_count + 1
    end
    events.emit("indexed", { path = path, skipped = "hash" })
    return
  end

  -- Parse off the main thread (async), then time-slice the extract walk so
  -- neither blocks the UI for more than ~a frame.
  indexer.ensure_languages(M.config.parser_path)
  local sp = vim.treesitter.get_string_parser(src, "org")
  coroutine.yield(function(resume)
    sp:parse(true, function()
      resume()
    end)
  end)
  local trees = sp:trees() or {}
  local root = trees[1] and trees[1]:root() or nil

  -- Yield the walk after this much wall time so it never blocks the UI
  -- for more than ~a frame; the parse already ran off the main thread.
  local slice_ms = M.config.scan_budget_ms or 8
  local last = vim.uv.hrtime()
  local headlines = {}
  if root then
    headlines = indexer._walk(root, sp, src, path, function()
      if (vim.uv.hrtime() - last) / 1e6 >= slice_ms then
        coroutine.yield("slice")
        last = vim.uv.hrtime()
      end
    end)
  end
  pcall(function()
    sp:destroy()
  end)

  -- The DB write is one transaction (it must not span yields -- an open
  -- write txn would block UI reads).  Give it its own slice so it doesn't
  -- pile onto the walk's tail.
  coroutine.yield("slice")

  local meta = {
    path = path,
    mtime = mtime or 0,
    hash = hash,
    file_tags = indexer.scan_filetags(src),
    file_todo_keywords = indexer.scan_todo_keywords(src),
  }
  local werr = h:transaction(function()
    indexer.write_body(h, meta, headlines, function() end)
  end)
  if werr then
    record_error("write " .. path .. ": " .. tostring(werr))
    notify("index failed for " .. path .. ": " .. tostring(werr), vim.log.levels.ERROR)
    return
  end

  M._last_status.last_file = path
  M._last_status.last_ts = os.time()
  if tier == "background" and M._scan.in_flight then
    M._scan.ok_count = M._scan.ok_count + 1
    M._scan.indexed_files = M._scan.indexed_files + 1
    M._scan.indexed_headlines = M._scan.indexed_headlines + #headlines
  end
  events.emit("indexed", { path = path, n_headlines = #headlines })
  notify_debug(("indexed %d headlines from %s"):format(#headlines, path))
end

-- Queue worker: drive index_body as a coroutine so indexing never blocks
-- the UI.  The coroutine yields either a thunk (resume after an off-thread
-- step) or "slice" (resume next event-loop tick); `done` advances the
-- queue once the file is fully indexed.
local function index_async(item, tier, done)
  local op = (type(item) == "string") and { kind = "index", path = item } or item
  local co = coroutine.create(function()
    index_body(op, tier)
  end)
  local function pump()
    local t0 = vim.uv.hrtime()
    local ok, signal = coroutine.resume(co)
    local slice_ms = (vim.uv.hrtime() - t0) / 1e6
    M._index_stats.slices = M._index_stats.slices + 1
    if slice_ms > M._index_stats.max_slice_ms then
      M._index_stats.max_slice_ms = slice_ms
    end
    if not ok then
      record_error("index " .. tostring(op.path) .. ": " .. tostring(signal))
      return done()
    end
    if coroutine.status(co) == "dead" then
      return done()
    end
    if type(signal) == "function" then
      signal(pump) -- off-thread step resumes us via the passed callback
    else
      require("organ.errors").schedule("organ.init", pump) -- "slice": let the UI breathe, continue next tick
    end
  end
  pump()
end

-- Recursive streaming scanner. Enqueues .org paths into the background tier
-- as they're discovered; never materialises the full file list in memory.
--
-- Pre-compile glob patterns to vim regex strings once per scan_walk call so
-- we never call vim.fn.* from a libuv fast-event callback.
local function compile_ignore_patterns()
  local pats = {}
  for _, glob in ipairs(M.config.ignore_globs) do
    pats[#pats + 1] = vim.fn.glob2regpat(glob)
  end
  return pats
end

local function is_ignored(rel_path, patterns)
  for _, pat in ipairs(patterns) do
    if vim.fn.match(rel_path, pat) >= 0 then
      return true
    end
  end
  return false
end

local walk = require("organ.walk")
local pathmod = require("organ.path")

local function scan_walk(dir, on_done)
  local root = dir
  local patterns = compile_ignore_patterns()
  -- Reset the visited set at the start of each walk so fire_scan_done
  -- can compute orphans = (DB - visited) without per-file fs_stat.
  M._scan.visited = {}
  walk.walk_async(
    root,
    M.config.scan_batch_size or 50,
    nil, -- on_dir: scanner doesn't track dirs
    function(full, _st)
      if not (full:match("%.org$") or full:match("%.org_archive$")) then
        return
      end
      local rel = full:sub(#root + 2)
      if is_ignored(rel, patterns) then
        return
      end
      local cf = pathmod.canonical(full)
      if cf then
        M._scan.visited[cf] = true
        queue.enqueue_background(cf)
      end
    end,
    on_done
  )
end

-- Semi-public helpers exposed so cmd.lua can call them without duplicating code.
-- Prefixed with _ to signal "internal use only".

function M._start_scan()
  return start_scan()
end
function M._scan_walk(dir, cb)
  return scan_walk(dir, cb)
end
function M._poll_scan_completion()
  return poll_scan_completion()
end

-- Setup helpers (extracted to keep M.setup() compact).

local function setup_validate_config()
  -- Capture templates: structural validation.
  if M.config.capture and M.config.capture.templates and #M.config.capture.templates > 0 then
    local ok, err =
      pcall(require("organ.capture.template").validate_all, M.config.capture.templates)
    if not ok then
      error("organ: capture templates invalid: " .. tostring(err))
    end
  end

  -- todo.sequence / todo.sequences: warn (don't error) on common shape
  -- mistakes.  Each (sub-)sequence should have a `|` divider between
  -- active and done states.
  local todo = M.config.todo or {}
  local raw = todo.sequences or todo.sequence
  if type(raw) == "table" and #raw > 0 then
    local function has_pipe(seq)
      for _, k in ipairs(seq) do
        if k == "|" then
          return true
        end
      end
      return false
    end
    local missing = {}
    if type(raw[1]) == "table" then
      for i, seq in ipairs(raw) do
        if not has_pipe(seq) then
          missing[#missing + 1] = i
        end
      end
    elseif not has_pipe(raw) then
      missing[#missing + 1] = 1
    end
    if #missing > 0 then
      require("organ.errors").schedule("organ.init", function()
        require("organ.notify").warn(
          "organ.todo sequence #"
            .. table.concat(missing, ", #")
            .. " has no `|` divider — every keyword will be treated as active. "
            .. 'Add `"|"` between active and done states (e.g. `{ "TODO", "|", "DONE" }`).'
        )
      end)
    end
  end

  -- agenda.views: each view must be a table with a `blocks` list.
  local agenda = M.config.agenda or {}
  if type(agenda.views) == "table" then
    for name, view in pairs(agenda.views) do
      if type(view) ~= "table" then
        error(("organ: agenda.views[%q] must be a table, got %s"):format(name, type(view)))
      end
      if view.blocks ~= nil and type(view.blocks) ~= "table" then
        error(
          ("organ: agenda.views[%q].blocks must be a list, got %s"):format(name, type(view.blocks))
        )
      end
    end
  end

  -- org_dir: warn when missing/nonexistent — not fatal because index/agenda
  -- still work for buffer-only scratch files, but the user almost certainly
  -- meant to point it at a real directory.
  local org_dir = M.config.org_dir
  if type(org_dir) == "string" and org_dir ~= "" then
    local stat = vim.uv.fs_stat(vim.fn.expand(org_dir))
    if not stat then
      require("organ.errors").schedule("organ.init", function()
        require("organ.notify").warn(
          ("organ.org_dir does not exist: %s — `:Org scan` will be a no-op until you create it."):format(
            org_dir
          )
        )
      end)
    elseif stat.type ~= "directory" then
      require("organ.errors").schedule("organ.init", function()
        require("organ.notify").warn(("organ.org_dir is not a directory: %s"):format(org_dir))
      end)
    end
  end

  -- db_path: parent directory must be creatable. Bail early if not — the
  -- user will get a much clearer message than the SQLite open error.
  local db_path = M.config.db_path
  if type(db_path) == "string" and db_path ~= "" then
    local parent = vim.fn.fnamemodify(db_path, ":h")
    local pstat = vim.uv.fs_stat(parent)
    if not pstat then
      local mk = vim.fn.mkdir(parent, "p")
      if mk == 0 then
        error(("organ.db_path parent dir cannot be created: %s"):format(parent))
      end
    end
  end
end

local function setup_highlights()
  -- Register highlight groups and per-keyword TODO colours immediately after
  -- config is finalised so that any buffers that open (or re-trigger FileType)
  -- before the autocmds are created already see the right colours.
  local hl = require("organ.highlights")
  hl.register()
  hl.register_todo_keywords(M.config.todo.sequences or M.config.todo.sequence)
  -- Eagerly publish agenda-side `@organ.agenda.*` groups so the user's
  -- `todo.keyword_faces` / `tags.faces` overrides are visible BEFORE the
  -- first agenda render (otherwise tests / users querying highlights
  -- right after `setup()` see empty groups).
  pcall(function()
    local agenda = require("organ.agenda")
    if agenda._register_highlights then
      agenda._register_highlights()
    end
  end)
end

local function setup_completion()
  pcall(function()
    require("organ.complete.cmp").maybe_register()
  end)
  pcall(function()
    require("organ.complete.blink").maybe_register()
  end)
end

local function setup_compat_listeners()
  -- Back-compat: user-supplied callbacks keep working, implemented via events.
  -- Remove any back-compat listeners from a prior setup() call to keep
  -- repeated setup() invocations (e.g. Lazy hot-reload) idempotent.
  for _, entry in ipairs(M._compat_listeners) do
    events.off(entry[1], entry[2])
  end
  M._compat_listeners = {}

  if M.config.on_index then
    local fn = function(p)
      local n = p.skipped and 0 or p.n_headlines
      pcall(M.config.on_index, p.path, n)
    end
    events.on("indexed", fn)
    table.insert(M._compat_listeners, { "indexed", fn })
  end
  if M.config.on_scan_done then
    local fn = function(p)
      pcall(M.config.on_scan_done, p.n_ok, p.errors)
    end
    events.on("scan_done", fn)
    table.insert(M._compat_listeners, { "scan_done", fn })
  end
  -- Auto-refresh Emacs `org-id-locations-file` after every scan so
  -- a parallel Emacs session sees fresh ID locations on its next
  -- load.  Only when `links.id_locations_file` is set.
  do
    local fn = function()
      pcall(require("organ.id")._maybe_auto_export)
    end
    events.on("scan_done", fn)
    table.insert(M._compat_listeners, { "scan_done", fn })
  end
  -- on_error keeps its direct call from record_error (unchanged).
end

local function setup_watcher(group)
  local watcher = require("organ.watcher")
  if M.config.watcher.enabled then
    watcher.start(M.config.watcher, M.config.org_dir)
  end
  if M.config.watcher.enabled and M.config.watcher.auto_watch_buffers then
    require("organ.errors").autocmd("BufReadPost", {
      group = vim.api.nvim_create_augroup("organ_watcher_buf", { clear = true }),
      pattern = { "*.org", "*.org_archive" },
      callback = function(args)
        local p = args.file or vim.api.nvim_buf_get_name(args.buf)
        if p == "" then
          return
        end
        local d = require("organ.path").canonical(vim.fn.fnamemodify(p, ":h"))
        if d then
          watcher.add_dir(d)
        end
      end,
    })
  end
end

local function setup_autocmds(group)
  require("organ.errors").autocmd("BufWritePost", {
    group = group,
    pattern = "*.org",
    callback = function(ev)
      local path = require("organ.path").canonical(ev.file)
      if not path then
        return
      end
      queue.enqueue_interactive(path)
    end,
  })

  require("organ.errors").autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(function()
        require("organ.watcher").stop()
      end)
      queue.drain_blocking(5000)
      local rt = require("organ.runtime")
      local handle = rt.db_if_open()
      if handle then
        pcall(indexer.finalise_stmts, handle)
        pcall(handle.close, handle)
        rt.reset()
      end
      M._db = nil
    end,
  })

  -- Per-buffer state is leaked unless cleared on wipeout.  Each stateful
  -- module registers its own teardown via organ.buf_state when it creates
  -- the state; this drains the registry for the wiped buffer.
  require("organ.errors").autocmd("BufWipeout", {
    group = group,
    pattern = { "*.org", "*.org_archive" },
    callback = function(ev)
      require("organ.buf_state").cleanup(ev.buf)
    end,
  })

  -- FileType=org keymaps, fold opts, indent, completion, and clock keymaps are
  -- primarily handled by ftplugin/org.lua (via lua/organ/ftplugin/*.lua).
  -- We also register a FileType autocmd here so that the attach functions fire
  -- in environments where filetype plugins are disabled (e.g. headless test
  -- runners that pass --noplugin).  In a normal Neovim session both paths fire;
  -- nvim_buf_set_keymap with noremap=true is idempotent, so double-attach is safe.
  require("organ.errors").autocmd("FileType", {
    group = group,
    pattern = "org",
    callback = function(ev)
      local bnum = ev.buf
      require("organ.ftplugin.core").attach(bnum)
      require("organ.ftplugin.subtree").attach(bnum)
      require("organ.ftplugin.inline_edit").attach(bnum)
      require("organ.ftplugin.property").attach(bnum)
      require("organ.ftplugin.table").attach(bnum)
      require("organ.ftplugin.tag_select").attach(bnum)
      require("organ.ftplugin.tempo").attach(bnum)
      require("organ.keymaps").attach(bnum)
      pcall(require("organ.keymaps").register_which_key)
      if (M.config.lsp or {}).enabled then
        pcall(function()
          require("organ.lsp").attach(bnum)
        end)
      end
    end,
  })
end

local function setup_scan_startup(group)
  if M.config.scan_on_startup then
    require("organ.errors").autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function()
        start_scan()
        scan_walk(M.config.org_dir, function()
          poll_scan_completion()
        end)
      end,
    })
  end
end

local function setup_global_keymaps()
  local cfg = M.config.global_keymaps
  if cfg == false then
    return
  end
  if type(cfg) ~= "table" then
    return
  end

  -- Map of config key → { :Org* command, which-key description }.
  -- Descriptions are action-first and short (LazyVim style); the `<Leader>o*`
  -- prefix already conveys the namespace, so no "organ:" needed.
  local CMD = {
    capture = { "Org capture", "Capture entry" },
    agenda = { "Org agenda", "Open agenda" },
    find = { "Org find", "Find headline" },
    find_file = { "Org find file", "Find org file" },
    find_link = { "Org find link", "Find link" },
    roam = { "Org roam", "Find/insert roam node" },
    roam_daily_today = { "Org roam daily today", "Today's daily note" },
    clock_in = { "Org clock in", "Clock in" },
    clock_out = { "Org clock out", "Clock out" },
    clock_report = { "Org clock report", "Clock report" },
    archive_subtree = { "Org archive subtree", "Archive subtree" },
    schedule = { "Org schedule", "Schedule headline" },
    deadline = { "Org deadline", "Set deadline" },
    id_create = { "Org id get_create", "Get/create headline ID" },
    scan = { "Org scan", "Scan org files" },
    status = { "Org status", "Show status" },
    narrow = { "Org narrow_to_subtree", "Narrow to subtree" },
    widen = { "Org widen", "Widen" },
    store_link = { "Org store_link", "Store link" },
    insert_link = { "Org insert_link", "Insert link" },
    attach = { "Org attach", "Attach file" },
    attach_open = { "Org attach open", "Open attachment" },
    cut_subtree = { "Org cut_subtree", "Cut subtree" },
    copy_subtree = { "Org copy_subtree", "Copy subtree" },
    paste_subtree = { "Org paste_subtree", "Paste subtree" },
  }

  local prefixes = {}
  for name, lhs in pairs(cfg) do
    local entry = CMD[name]
    if entry and type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set("n", lhs, "<Cmd>" .. entry[1] .. "<CR>", { silent = true, desc = entry[2] })
      local p = lhs:match("^(<[Ll]eader>.)") -- the shared prefix, e.g. <Leader>o
      if p then
        prefixes[p] = true
      end
    end
  end

  -- Label the global prefix(es) as a which-key group so e.g. <Leader>o shows
  -- an "org" heading instead of an unlabeled menu.  No-op without which-key;
  -- the user can relabel by registering their own group for the prefix.
  local ok_wk, wk = pcall(require, "which-key")
  if ok_wk and wk and wk.add then
    local groups = {}
    for p in pairs(prefixes) do
      groups[#groups + 1] = { p, group = "org" }
    end
    if #groups > 0 then
      pcall(wk.add, groups)
    end
  end
end

local function setup_timezone()
  -- Synchronously detect country from system timezone (sub-ms fs_readlink).
  if M.config.todo and not M.config.todo.default_country then
    local ok_tz, tz = pcall(require, "organ.todo.timezone")
    if ok_tz then
      M.config.todo.default_country = tz.detect_country()
    end
  end
  -- Async warm (non-blocking).
  if M.config.todo and M.config.todo.default_country then
    local ok_h, hol = pcall(require, "organ.holidays")
    if ok_h then
      require("organ.errors").schedule("organ.init", function()
        hol.warm(M.config.todo.default_country, 4)
      end)
    end
  end
end

-- Public API.

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  setup_validate_config()

  -- Remove subcommands for any feature whose `enabled` flag is false.
  -- plugin/organ.lua registers the full :Org subcommand tree at startup
  -- so that lazy-loading and tab-completion work before setup() is
  -- called.  A disabled feature should leave no trace in the
  -- dispatcher.  Each entry in feature_commands is the dispatch path
  -- (e.g. `"find link"`, `"clock in"`) and we walk the tree to remove
  -- the leaf at that path.
  do
    local feat_cmds = require("organ.feature_commands").feature_commands
    local tree = M._subcommand_tree
    if type(tree) == "table" then
      for feat, paths in pairs(feat_cmds) do
        local cfg = M.config[feat]
        if type(cfg) == "table" and cfg.enabled == false then
          for _, path in ipairs(paths) do
            local tokens = vim.split(path, "%s+", { trimempty = true })
            local node = { children = tree }
            for i = 1, #tokens - 1 do
              node = node.children and node.children[tokens[i]]
              if not node then
                break
              end
            end
            if node and node.children then
              node.children[tokens[#tokens]] = nil
            end
          end
        end
      end
    end
  end

  setup_highlights()
  setup_compat_listeners()
  -- Queue must be initialised at setup time so BufWritePost / scan callbacks
  -- can enqueue immediately. The DB is opened lazily on first queue drain.
  queue.init({
    process = index_async,
    debounce_ms = M.config.debounce_ms,
    row_chunk = M.config.row_chunk,
  })
  local group = vim.api.nvim_create_augroup("organ", { clear = true })
  setup_watcher(group)
  setup_autocmds(group)
  setup_scan_startup(group)
  setup_global_keymaps()
  -- Defer non-essential work: completion registration, timezone detect, and
  -- clock state reload are all safe to run one event-loop tick later.
  require("organ.errors").schedule("organ.init", function()
    setup_completion()
    setup_timezone()
    pcall(function()
      require("organ.clock").setup_resume()
    end)
    pcall(function()
      require("organ.alarms").start()
    end)
  end)
end

function M.db_handle()
  return require("organ.runtime").db()
end

function M.scan_blocking(dir, timeout_ms)
  start_scan()
  local scan_done = false
  scan_walk(dir or M.config.org_dir, function()
    scan_done = true
  end)
  -- Wait for the filesystem walk to finish before draining, so that all
  -- files are enqueued before we declare the queue empty.
  local deadline = (timeout_ms or 60000)
  if not vim.wait(deadline, function()
    return scan_done
  end, 10) then
    return false
  end
  local ok = queue.drain_blocking(deadline)
  fire_scan_done()
  return ok
end

function M.drain_blocking(timeout_ms)
  return queue.drain_blocking(timeout_ms)
end

return M
