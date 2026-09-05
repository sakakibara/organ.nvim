-- lua/organ/indexer/init.lua
--
-- Persistence layer of the indexer package: writes extracted headline
-- records into the SQLite index (prepared-statement cache, file/headline
-- upserts, forget, skip-checks) and hosts the :Org index/scan/status
-- commands.  Extraction (org source / tree-sitter -> record tables)
-- lives in organ.indexer.extract; its members are re-exported below so
-- require("organ.indexer") keeps a single surface.
local M = {}

local obuf = require("organ.buf")
local extract = require("organ.indexer.extract")

-- Extraction layer, re-exported. Tests and the scan pipeline consume
-- these through require("organ.indexer"); the underscore members are
-- exposed for tests.
M.extract = extract.extract
M.ensure_languages = extract.ensure_languages
M.scan_filetags = extract.scan_filetags
M.scan_todo_keywords = extract.scan_todo_keywords
M._walk = extract._walk
M._extractor_version = extract._extractor_version
M._date_iso = extract._date_iso
M._parse_ts_body = extract._parse_ts_body
M._inline_parser_path = extract._inline_parser_path

local db = require("organ.db")

local SQL = {
  ins_file = "INSERT OR REPLACE INTO files(path, mtime, hash, indexed, extractor_version) VALUES (?, ?, ?, strftime('%s','now'), ?)",
  del_hl = "DELETE FROM headlines WHERE file_path = ?",
  del_hl_elsewhere = "DELETE FROM headlines WHERE id = ? AND file_path <> ?",
  ins_hl = "INSERT INTO headlines(id, file_path, parent_id, level, title, "
    .. "todo_state, priority, scheduled, deadline, closed, "
    .. "scheduled_date, deadline_date, closed_date, "
    .. "line_start, line_end, commented) "
    .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  -- Tags are a set (`:work:work:` is one tag to `org-get-tags`); a
  -- repeated property key resolves to its last value, as `org-entry-get`
  -- and the tags-view property matcher both do.
  ins_tag = "INSERT OR IGNORE INTO tags(headline_id, tag) VALUES (?, ?)",
  ins_prop = "INSERT OR REPLACE INTO properties(headline_id, key, value) VALUES (?, ?, ?)",
  ins_link = "INSERT INTO links(source_headline_id, target_type, target, description, line) "
    .. "VALUES (?, ?, ?, ?, ?)",
  ins_clock = "INSERT INTO clock_entries(headline_id, start_ts, end_ts, duration_seconds) "
    .. "VALUES (?, ?, ?, ?)",
  ins_habit = "INSERT OR IGNORE INTO habit_completions(headline_id, date) VALUES (?, ?)",
  del_habit_for_hl = "DELETE FROM habit_completions WHERE headline_id = ?",
  ins_state = "INSERT OR REPLACE INTO state_changes(headline_id, ts, from_state, to_state, note) "
    .. "VALUES (?, ?, ?, ?, ?)",
  del_state_for_hl = "DELETE FROM state_changes WHERE headline_id = ?",
  upd_file_stamp = "UPDATE files SET mtime = ?, hash = ?, extractor_version = ? WHERE path = ?",
  del_file_tags = "DELETE FROM file_tags WHERE file_path = ?",
  ins_file_tag = "INSERT INTO file_tags (file_path, tag) VALUES (?, ?)",
  ins_alias = "INSERT OR IGNORE INTO aliases (headline_id, alias) VALUES (?, ?)",
  del_file_todo_kw = "DELETE FROM file_todo_keywords WHERE file_path = ?",
  ins_file_todo_kw = "INSERT INTO file_todo_keywords"
    .. "(file_path, sequence_idx, ordinal, keyword, is_done) VALUES (?, ?, ?, ?, ?)",
}

local function get_stmts(h)
  if h._organ_stmts then
    return h._organ_stmts
  end
  local s = {}
  for name, sql in pairs(SQL) do
    local stmt, err = h:prepare(sql)
    if not stmt then
      for _, done in pairs(s) do
        done:finalize()
      end
      return nil, "prepare " .. name .. ": " .. tostring(err)
    end
    s[name] = stmt
  end
  h._organ_stmts = s
  return s
end

function M.write_body(h, meta, headlines, on_yield)
  local stmts, err = get_stmts(h)
  if not stmts then
    error(err)
  end

  -- Canonicalize once at the write boundary so every column in the DB
  -- shares a single path form (symlink-resolved + absolute).  Query
  -- callers canonicalize on the read side too — this keeps both sides
  -- aligned regardless of what form the caller passed in.
  meta.path = require("organ.path").canonical(meta.path) or meta.path

  local DONE = db.SQLITE_DONE

  stmts.ins_file:reset()
  stmts.ins_file:bind_text(1, meta.path)
  stmts.ins_file:bind_int64(2, 0)
  stmts.ins_file:bind_text(3, "")
  stmts.ins_file:bind_text(4, extract._extractor_version())
  local rc = stmts.ins_file:step()
  if rc ~= DONE then
    error(string.format("ins_file rc=%d path=%s", rc, meta.path))
  end

  stmts.del_hl:reset()
  stmts.del_hl:bind_text(1, meta.path)
  local rc2 = stmts.del_hl:step()
  if rc2 ~= DONE then
    error(string.format("del_hl rc=%d path=%s", rc2, meta.path))
  end

  local row_chunk = h._organ_row_chunk or 10000
  local rows = 0
  for _, hl in ipairs(headlines) do
    -- `headlines.id` is global, so a headline that moved here from
    -- another file is still claimed by that file's stale row.  Release
    -- it first; org-id resolves a duplicate `:ID:` to the last file
    -- registered too.
    stmts.del_hl_elsewhere:reset()
    stmts.del_hl_elsewhere:bind_text(1, hl.id)
    stmts.del_hl_elsewhere:bind_text(2, meta.path)
    local rcde = stmts.del_hl_elsewhere:step()
    if rcde ~= DONE then
      error(string.format("del_hl_elsewhere rc=%d id=%s", rcde, tostring(hl.id)))
    end

    stmts.ins_hl:reset()
    stmts.ins_hl:bind_text(1, hl.id)
    stmts.ins_hl:bind_text(2, meta.path)
    stmts.ins_hl:bind_text(3, hl.parent_id)
    stmts.ins_hl:bind_int(4, hl.level)
    stmts.ins_hl:bind_text(5, hl.title)
    stmts.ins_hl:bind_text(6, hl.todo_state)
    stmts.ins_hl:bind_text(7, hl.priority)
    stmts.ins_hl:bind_text(8, hl.scheduled)
    stmts.ins_hl:bind_text(9, hl.deadline)
    stmts.ins_hl:bind_text(10, hl.closed)
    stmts.ins_hl:bind_text(11, hl.scheduled_date)
    stmts.ins_hl:bind_text(12, hl.deadline_date)
    stmts.ins_hl:bind_text(13, hl.closed_date)
    stmts.ins_hl:bind_int(14, hl.line_start)
    stmts.ins_hl:bind_int(15, hl.line_end)
    stmts.ins_hl:bind_int(16, hl.commented or 0)
    local rch = stmts.ins_hl:step()
    if rch ~= DONE then
      error(string.format("ins_hl rc=%d path=%s id=%s", rch, meta.path, tostring(hl.id)))
    end

    for _, tag in ipairs(hl.tags or {}) do
      stmts.ins_tag:reset()
      stmts.ins_tag:bind_text(1, hl.id)
      stmts.ins_tag:bind_text(2, tag)
      local rct = stmts.ins_tag:step()
      if rct ~= DONE then
        error(string.format("ins_tag rc=%d id=%s tag=%s", rct, tostring(hl.id), tostring(tag)))
      end
    end
    for _, p in ipairs(hl.properties or {}) do
      stmts.ins_prop:reset()
      stmts.ins_prop:bind_text(1, hl.id)
      stmts.ins_prop:bind_text(2, p.key)
      stmts.ins_prop:bind_text(3, p.value)
      local rcp = stmts.ins_prop:step()
      if rcp ~= DONE then
        error(string.format("ins_prop rc=%d id=%s key=%s", rcp, tostring(hl.id), tostring(p.key)))
      end
    end
    for _, p in ipairs(hl.properties or {}) do
      if p.key == "ROAM_ALIASES" then
        for _, alias in ipairs(extract._parse_alias_value(p.value or "")) do
          stmts.ins_alias:reset()
          stmts.ins_alias:bind_text(1, hl.id)
          stmts.ins_alias:bind_text(2, alias)
          local rca = stmts.ins_alias:step()
          if rca ~= DONE then
            error(
              string.format("ins_alias rc=%d id=%s alias=%s", rca, tostring(hl.id), tostring(alias))
            )
          end
        end
      end
    end
    local link_mod = require("organ.link")
    for _, lk in ipairs(hl.links or {}) do
      local ttype, tstrip = link_mod.resolve(lk.target)
      stmts.ins_link:reset()
      stmts.ins_link:bind_text(1, hl.id)
      stmts.ins_link:bind_text(2, ttype)
      stmts.ins_link:bind_text(3, tstrip)
      stmts.ins_link:bind_text(4, lk.description)
      stmts.ins_link:bind_int(5, lk.line)
      local rcl = stmts.ins_link:step()
      if rcl ~= DONE then
        error(
          string.format("ins_link rc=%d path=%s target=%s", rcl, meta.path, tostring(lk.target))
        )
      end
    end

    for _, c in ipairs(hl.clocks or {}) do
      stmts.ins_clock:reset()
      stmts.ins_clock:bind_text(1, hl.id)
      stmts.ins_clock:bind_int(2, c.start_ts)
      if c.end_ts then
        stmts.ins_clock:bind_int(3, c.end_ts)
        stmts.ins_clock:bind_int(4, c.duration_seconds or (c.end_ts - c.start_ts))
      else
        stmts.ins_clock:bind_null(3)
        stmts.ins_clock:bind_null(4)
      end
      local rcc = stmts.ins_clock:step()
      if rcc ~= DONE then
        error(string.format("ins_clock rc=%d id=%s", rcc, tostring(hl.id)))
      end
    end

    -- Habit completion dates from LOGBOOK State→DONE entries.  Always
    -- replace the per-headline set so completions removed from the file
    -- (manual edits) propagate to the index.
    if stmts.del_habit_for_hl and stmts.ins_habit then
      stmts.del_habit_for_hl:reset()
      stmts.del_habit_for_hl:bind_text(1, hl.id)
      stmts.del_habit_for_hl:step()
      for _, date in ipairs(hl.habit_completions or {}) do
        stmts.ins_habit:reset()
        stmts.ins_habit:bind_text(1, hl.id)
        stmts.ins_habit:bind_text(2, date)
        local rch = stmts.ins_habit:step()
        if rch ~= DONE then
          error(
            string.format("ins_habit rc=%d id=%s date=%s", rch, tostring(hl.id), tostring(date))
          )
        end
      end
    end

    -- Every state-change entry from the LOGBOOK drawer.  Replace the
    -- whole per-headline set on each pass so manual edits to the
    -- LOGBOOK propagate.  Powers `:Org agenda` log mode `state` item.
    if stmts.del_state_for_hl and stmts.ins_state then
      stmts.del_state_for_hl:reset()
      stmts.del_state_for_hl:bind_text(1, hl.id)
      stmts.del_state_for_hl:step()
      for _, sc in ipairs(hl.state_changes or {}) do
        stmts.ins_state:reset()
        stmts.ins_state:bind_text(1, hl.id)
        stmts.ins_state:bind_int(2, sc.ts)
        if sc.from_state then
          stmts.ins_state:bind_text(3, sc.from_state)
        else
          stmts.ins_state:bind_null(3)
        end
        stmts.ins_state:bind_text(4, sc.to_state)
        if sc.note and sc.note ~= "" then
          stmts.ins_state:bind_text(5, sc.note)
        else
          stmts.ins_state:bind_null(5)
        end
        local rcs = stmts.ins_state:step()
        if rcs ~= DONE then
          error(string.format("ins_state rc=%d id=%s ts=%d", rcs, tostring(hl.id), sc.ts))
        end
      end
    end

    rows = rows + 1
    if rows % row_chunk == 0 and on_yield then
      on_yield()
    end
  end

  stmts.upd_file_stamp:reset()
  stmts.upd_file_stamp:bind_int64(1, meta.mtime or 0)
  stmts.upd_file_stamp:bind_text(2, meta.hash or "")
  stmts.upd_file_stamp:bind_text(3, extract._extractor_version())
  stmts.upd_file_stamp:bind_text(4, meta.path)
  local rcu = stmts.upd_file_stamp:step()
  if rcu ~= DONE then
    error(string.format("upd_file_stamp rc=%d path=%s", rcu, meta.path))
  end

  stmts.del_file_tags:reset()
  stmts.del_file_tags:bind_text(1, meta.path)
  local rcd = stmts.del_file_tags:step()
  if rcd ~= DONE then
    error(string.format("del_file_tags rc=%d path=%s", rcd, meta.path))
  end
  for _, tag in ipairs(meta.file_tags or {}) do
    stmts.ins_file_tag:reset()
    stmts.ins_file_tag:bind_text(1, meta.path)
    stmts.ins_file_tag:bind_text(2, tag)
    local rcft = stmts.ins_file_tag:step()
    if rcft ~= DONE then
      error(string.format("ins_file_tag rc=%d path=%s tag=%s", rcft, meta.path, tostring(tag)))
    end
  end

  -- File-level `#+TODO:` keywords (Emacs per-file todo overrides).
  stmts.del_file_todo_kw:reset()
  stmts.del_file_todo_kw:bind_text(1, meta.path)
  local rcdk = stmts.del_file_todo_kw:step()
  if rcdk ~= DONE then
    error(string.format("del_file_todo_kw rc=%d path=%s", rcdk, meta.path))
  end
  for _, kw in ipairs(meta.file_todo_keywords or {}) do
    stmts.ins_file_todo_kw:reset()
    stmts.ins_file_todo_kw:bind_text(1, meta.path)
    stmts.ins_file_todo_kw:bind_int(2, kw.sequence_idx)
    stmts.ins_file_todo_kw:bind_int(3, kw.ordinal)
    stmts.ins_file_todo_kw:bind_text(4, kw.keyword)
    stmts.ins_file_todo_kw:bind_int(5, kw.is_done)
    local rcfk = stmts.ins_file_todo_kw:step()
    if rcfk ~= DONE then
      error(string.format("ins_file_todo_kw rc=%d path=%s kw=%s", rcfk, meta.path, kw.keyword))
    end
  end
end

-- Drop any roam.linkify completion-index cache after a write batch
-- so the next blink.cmp keystroke rebuilds against current data.
-- Uses package.loaded to avoid forcing a load if linkify hasn't been
-- required yet (e.g., indexing during early startup before any roam
-- command has touched the module).
local function invalidate_linkify_cache()
  local lk = package.loaded["organ.roam.linkify"]
  if lk and lk.invalidate_index then
    lk.invalidate_index()
  end
end

function M.write(h, meta, headlines, on_yield)
  local err = h:transaction(function()
    M.write_body(h, meta, headlines, on_yield)
  end)
  if not err then
    invalidate_linkify_cache()
    local ok, ev = pcall(require, "organ.events")
    if ok then
      ev.emit("indexed", { path = meta.path, n_headlines = #headlines })
    end
  end
  return err
end

function M.forget_body(h, path)
  local stmt, perr = h:prepare("DELETE FROM files WHERE path = ?")
  if not stmt then
    error("forget prepare: " .. tostring(perr))
  end
  stmt:bind_text(1, path)
  local rc = stmt:step()
  stmt:finalize()
  if rc ~= db.SQLITE_DONE then
    error(string.format("forget rc=%d path=%s", rc, path))
  end
  local ok, ev = pcall(require, "organ.events")
  if ok then
    ev.emit("unindexed", { path = path })
  end
end

function M.forget(h, path)
  local err = h:transaction(function()
    M.forget_body(h, path)
  end)
  if not err then
    invalidate_linkify_cache()
  end
  return err
end

function M.forget_async(path)
  local q = require("organ.queue")
  q.enqueue_background_op({ kind = "delete", path = path })
end

function M.finalise_stmts(h)
  if not h._organ_stmts then
    return
  end
  for _, s in pairs(h._organ_stmts) do
    s:finalize()
  end
  h._organ_stmts = nil
end

-- Returns the number of rows currently in the `files` table — the
-- authoritative "is the index populated" signal.  Cheap; one COUNT query.
function M.files_count(h)
  local s, err = h:prepare("SELECT COUNT(*) FROM files")
  if not s then
    return 0, err
  end
  local n = 0
  if s:step() == db.SQLITE_ROW then
    n = s:column_int64(0)
  end
  s:finalize()
  return n
end

function M.should_skip(h, file_path, mtime, hash)
  -- Match the canonical form used by write_body so a path passed in
  -- raw (`/var/...` on macOS) finds the row written under its
  -- symlink-resolved form (`/private/var/...`).
  file_path = require("organ.path").canonical(file_path) or file_path
  local s, err = h:prepare("SELECT mtime, hash, extractor_version FROM files WHERE path = ?")
  if not s then
    return nil, err
  end
  s:bind_text(1, file_path)
  local step = s:step()
  local stored_mtime, stored_hash, stored_version
  if step == db.SQLITE_ROW then
    stored_mtime = s:column_int64(0)
    stored_hash = s:column_text(1)
    stored_version = s:column_text(2)
  end
  s:finalize()

  if stored_mtime == nil then
    return nil
  end
  -- Cache invalidation on extractor change: if the row was stamped
  -- with a different extractor_version (parser binary rebuild,
  -- indexer source modification, schema change), force-re-extract
  -- regardless of mtime/hash match.  Users never have to know about
  -- :Org scan! after an organ.nvim update — stale rows reroll
  -- transparently on the next scan.
  if stored_version ~= extract._extractor_version() then
    return nil
  end
  -- One-second mtime granularity cannot separate "unchanged" from "saved
  -- again within the same second as the last index", so equality only
  -- proves staleness once that second has passed.
  if mtime ~= nil and stored_mtime == mtime and mtime < os.time() then
    return "mtime"
  end
  if hash ~= nil and stored_hash == hash then
    return "hash"
  end
  return nil
end

function M.index_file_sync(path)
  local h = require("organ.runtime").db()
  assert(h, "organ.runtime.db() returned nil — call organ.setup() before index_file_sync")
  local parser_path = require("organ.buf_config").read(nil, "parser_path")

  -- Canonicalize before any DB write so all `file_path` rows are
  -- symlink-resolved + absolute.  Without this, a caller indexing
  -- `/var/x/a.org` and then querying via `path.canonical(...)`
  -- (which resolves to `/private/var/x/a.org` on macOS) would miss
  -- the row.  Match the query side's canonicalization.
  path = require("organ.path").canonical(path) or path

  local f = assert(io.open(path, "r"))
  local src = f:read("*a")
  f:close()

  -- Hash short-circuit: byte-for-byte identical content → skip the parse +
  -- DB write. We deliberately don't use the mtime fast-path here: a save
  -- triggered within the same second as the prior index would falsely
  -- match. Per-file cost is one sha256 + one indexed SELECT.
  local hash = vim.fn.sha256(src)
  if M.should_skip(h, path, nil, hash) == "hash" then
    return
  end

  local st = vim.loop.fs_stat(path)
  local mtime = st and st.mtime.sec or 0

  -- Through the facade member so :Org profile's wrap of M.extract sees
  -- this call too.
  local headlines = M.extract(src, path, parser_path)
  local file_tags = extract.scan_filetags(src)
  local file_todo_keywords = extract.scan_todo_keywords(src)
  local meta = {
    path = path,
    mtime = mtime,
    hash = hash,
    file_tags = file_tags,
    file_todo_keywords = file_todo_keywords,
  }

  local err = h:transaction(function()
    M.write_body(h, meta, headlines, function() end)
  end)
  if err then
    error("index_file_sync failed for " .. path .. ": " .. tostring(err))
  end
  invalidate_linkify_cache()
end

local function notify_msg(msg, level)
  if not require("organ.buf_config").read(nil, "notify") then
    return
  end
  require("organ.errors").schedule("organ.indexer.init", function()
    require("organ.notify").notify(level or vim.log.levels.INFO, msg)
  end)
end

M.commands = {
  index = {
    fn = function(cmd)
      local path = cmd.args ~= "" and cmd.args or vim.api.nvim_buf_get_name(0)
      if path == "" then
        require("organ.notify").error("no file")
        return
      end
      local canon = require("organ.path").canonical(path)
      if not canon then
        return
      end
      -- :Org index! force-reindexes by forgetting the existing DB row first,
      -- so the mtime/hash short-circuit can't skip a stale row from a
      -- previous parser version.
      if cmd.bang then
        M.forget(require("organ.runtime").db(), canon)
        notify_msg("force-reindex: " .. canon)
      end
      require("organ.queue").enqueue_interactive(canon)
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Reindex an org file. `:Org index!` clears the DB row first (fixes stale data).",
  },
  prune_missing = {
    fn = function()
      -- Walk every indexed file path and forget any whose file no
      -- longer exists on disk.  Cleans up rows left behind by tests,
      -- crash-killed nvim sessions, or files moved out of band.
      local h = require("organ.runtime").db()
      local s = h:prepare("SELECT path FROM files")
      local paths, missing = {}, {}
      while s:step() == require("organ.db").SQLITE_ROW do
        paths[#paths + 1] = s:column_text(0)
      end
      s:finalize()
      for _, p in ipairs(paths) do
        if vim.fn.filereadable(p) == 0 then
          missing[#missing + 1] = p
        end
      end
      for _, p in ipairs(missing) do
        pcall(M.forget, h, p)
      end
      notify_msg(("pruned %d / %d (missing files dropped from index)"):format(#missing, #paths))
    end,
    desc = "Drop DB rows for indexed files that no longer exist on disk",
  },
  scan = {
    fn = function(cmd)
      local organ = require("organ")
      local h = require("organ.runtime").db()
      if cmd and cmd.bang then
        notify_msg(
          "force-rescan: clearing index for " .. require("organ.buf_config").read(nil, "org_dir")
        )
        local org_dir = require("organ.buf_config").read(nil, "org_dir")
        local prefix = (require("organ.path").canonical(org_dir) or org_dir):gsub("/+$", "") .. "/"
        local s = h:prepare("SELECT path FROM files WHERE path LIKE ? ESCAPE '\\'")
        s:bind_text(1, (prefix:gsub("[\\%%_]", "\\%0")) .. "%")
        local paths = {}
        while s:step() == require("organ.db").SQLITE_ROW do
          paths[#paths + 1] = s:column_text(0)
        end
        s:finalize()
        for _, p in ipairs(paths) do
          pcall(M.forget, h, p)
        end
      end
      -- Auto-prune missing files across the WHOLE DB on every scan.
      -- The watcher only sees deletes inside org_dir; files indexed
      -- outside (tests, manually edited paths, files moved before
      -- the watcher was running) accumulate as orphan rows otherwise
      -- and surface in `:Org find` long after the file is gone.
      local s = h:prepare("SELECT path FROM files")
      local paths, missing = {}, 0
      while s:step() == require("organ.db").SQLITE_ROW do
        paths[#paths + 1] = s:column_text(0)
      end
      s:finalize()
      for _, p in ipairs(paths) do
        if vim.fn.filereadable(p) == 0 then
          pcall(M.forget, h, p)
          missing = missing + 1
        end
      end
      if missing > 0 then
        notify_msg(("pruned %d orphan file row(s)"):format(missing))
      end
      notify_msg("scanning " .. require("organ.buf_config").read(nil, "org_dir"))
      organ._start_scan()
      organ._scan_walk(require("organ.buf_config").read(nil, "org_dir"), function()
        notify_msg("scan enqueued; draining in background")
        organ._poll_scan_completion()
      end)
    end,
    bang = true,
    desc = "Scan org_dir, index all .org files, prune missing-file rows. `:Org scan!` also clears org_dir.",
  },
  status = {
    fn = function()
      local organ = require("organ")
      local queue = require("organ.queue")
      local ui, bg = queue.depth()
      local indexed = 0
      local rt_ok, rt = pcall(require, "organ.runtime")
      if rt_ok then
        local h_ok, h = pcall(rt.db)
        if h_ok and h then
          indexed = M.files_count(h)
        end
      end
      local msg = string.format(
        "organ: db=%s  files_indexed=%d  queue(int/bg)=%d/%d  last=%s  errors=%d",
        require("organ.buf_config").read(nil, "db_path"),
        indexed,
        ui,
        bg,
        organ._last_status.last_file or "(none this session)",
        #organ._last_status.errors
      )
      local w = require("organ.watcher")
      local pending = 0
      for _ in pairs(w._tombstones or {}) do
        pending = pending + 1
      end
      msg = msg .. string.format("  watcher=%d/%d", #w.watched_dirs(), pending)
      vim.api.nvim_echo({ { msg, "None" } }, false, {})
    end,
    desc = "Show organ queue + DB status",
  },
  ["dump files"] = {
    fn = function()
      local h = require("organ.runtime").db()
      local db = require("organ.db")
      local s, err = h:prepare([[
        SELECT f.path, COUNT(hl.id) AS n
        FROM files f
        LEFT JOIN headlines hl ON hl.file_path = f.path
        GROUP BY f.path
        ORDER BY n ASC, f.path
      ]])
      if not s then
        require("organ.notify").error("dump_files: " .. tostring(err))
        return
      end
      local lines = {
        "Indexed files (path | headline count)",
        "Files with `headlines=0` are red flags — parser likely failed.",
        string.rep("-", 100),
      }
      while s:step() == db.SQLITE_ROW do
        lines[#lines + 1] = string.format("%6d  %s", s:column_int64(1), s:column_text(0) or "")
      end
      s:finalize()
      vim.cmd("vnew")
      obuf.set_lines(0, 0, -1, lines)
      vim.bo.buftype = "nofile"
      vim.bo.bufhidden = "wipe"
      vim.bo.modifiable = false
      vim.api.nvim_buf_set_name(0, "[OrgDumpFiles]")
    end,
    desc = "List indexed files with headline counts",
  },
  ["dump scheduled"] = {
    fn = function()
      local h = require("organ.runtime").db()
      local db = require("organ.db")
      local s, err = h:prepare([[
        SELECT file_path, title, todo_state, scheduled_date, deadline_date
        FROM headlines
        WHERE scheduled_date IS NOT NULL OR deadline_date IS NOT NULL
        ORDER BY file_path, scheduled_date, deadline_date
      ]])
      if not s then
        require("organ.notify").error("dump_scheduled: " .. tostring(err))
        return
      end
      local lines = {
        "Scheduled / deadline-bearing headlines in DB",
        "(file_path | TODO | scheduled | deadline | title)",
        string.rep("-", 100),
      }
      local n = 0
      while s:step() == db.SQLITE_ROW do
        n = n + 1
        local fp = (s:column_text(0) or ""):match("([^/]+/?[^/]*)$") or s:column_text(0)
        lines[#lines + 1] = string.format(
          "%-40s | %-6s | %-16s | %-10s | %s",
          fp,
          s:column_text(2) or "-",
          s:column_text(3) or "",
          s:column_text(4) or "",
          s:column_text(1) or ""
        )
      end
      s:finalize()
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format("(%d rows)", n)
      vim.cmd("vnew")
      obuf.set_lines(0, 0, -1, lines)
      vim.bo.buftype = "nofile"
      vim.bo.bufhidden = "wipe"
      vim.bo.modifiable = false
      vim.api.nvim_buf_set_name(0, "[OrgDumpScheduled]")
    end,
    desc = "Open a scratch buffer with every scheduled/deadline headline in the DB",
  },
}

return M
