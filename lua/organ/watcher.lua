-- Filesystem watcher for organ.nvim.

local M = {}

local on_event

-- Reset between tests; init.lua re-initialises via M.start.
M._dirs = {}
M._tombstones = {}
M._rescan = nil -- uv timer
M._opts = nil
-- Polling state: { [path] = uv_fs_poll_handle }
M._pollers = M._pollers or {}

-- Pure filter. Returns true iff path is a watchable .org / .org_archive file
-- and matches none of the ignore patterns.
function M.should_handle(path, ignore_patterns)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:sub(1, 1) ~= "/" then
    return false
  end -- absolute paths only
  if not (path:match("%.org$") or path:match("%.org_archive$")) then
    return false
  end
  for _, pat in ipairs(ignore_patterns or {}) do
    -- Normalize component-boundary patterns: ^X becomes /X (to match as path component)
    local normalized_pat = pat
    if pat:sub(1, 1) == "^" then
      normalized_pat = "/" .. pat:sub(2)
    end
    if path:match(normalized_pat) then
      return false
    end
  end
  return true
end

local canonical = require("organ.path").canonical

local function is_macos()
  return vim.loop.os_uname().sysname == "Darwin"
end

local function open_handle(path, recursive)
  local h = vim.loop.new_fs_event()
  -- vim.loop.new_fs_event:start(path, flags, cb).
  -- Recursive mode is honoured on macOS/Windows; ignored on Linux.
  local ok, err = pcall(function()
    h:start(path, recursive and { recursive = true } or {}, function(err2, filename, events)
      if err2 then
        return
      end
      vim.schedule(function()
        on_event(path, filename, events)
      end)
    end)
  end)
  if not ok then
    pcall(function()
      h:close()
    end)
    return nil, err
  end
  return h
end

-- add_dir(path [, force])
-- force=true bypasses the macOS "covered by parent recursive watcher" check.
-- Use it when adding an explicit watcher for a symlinked subdir, because
-- FSEvents recursive mode does not follow symlinks.
function M.add_dir(path, force)
  local p = canonical(path)
  if not p then
    return false
  end
  if M._dirs[p] then
    return false
  end
  -- Skip if a parent recursive macOS watcher already covers this path,
  -- UNLESS force is set (symlinked subdirs need explicit watchers).
  if is_macos() and not force then
    for parent, st in pairs(M._dirs) do
      if st.recursive and (p == parent or p:sub(1, #parent + 1) == parent .. "/") then
        return false
      end
    end
  end
  local recursive = is_macos()
  local h, err = open_handle(p, recursive)
  if not h then
    -- Surface via on_error hook if available; never abort.
    pcall(function()
      local on_error = require("organ.buf_config").read(nil, "on_error")
      if on_error then
        on_error("watcher add_dir " .. p .. ": " .. tostring(err))
      end
    end)
    return false
  end
  M._dirs[p] = { handle = h, recursive = recursive }
  return true
end

function M.is_watching(path)
  local p = canonical(path)
  return p ~= nil and M._dirs[p] ~= nil
end

function M.watched_dirs()
  local out = {}
  for p in pairs(M._dirs) do
    out[#out + 1] = p
  end
  return out
end

local function tombstone_path(p)
  if M._tombstones[p] then
    pcall(function()
      M._tombstones[p]:stop()
    end)
    pcall(function()
      M._tombstones[p]:close()
    end)
    M._tombstones[p] = nil
  end
end

local function schedule_delete(p)
  tombstone_path(p)
  local grace = (M._opts and M._opts.delete_grace_ms) or 500
  local t = vim.defer_fn(function()
    M._tombstones[p] = nil
    local indexer = require("organ.indexer")
    indexer.forget_async(p)
  end, grace)
  M._tombstones[p] = t
end

on_event = function(dir, filename, events)
  if not filename then
    return
  end
  local full = dir .. "/" .. filename
  local p = canonical(full)
  if not p then
    return
  end
  local ignore = (M._opts and M._opts.ignore) or {}
  -- For directory events on Linux (fs_event fires "rename" on subdir create),
  -- fs_stat tells us it's a dir and we add a watcher; should_handle then
  -- rejects it as not-an-org-file and we exit.
  vim.loop.fs_stat(full, function(_serr, st)
    vim.schedule(function()
      if st and st.type == "directory" then
        if not is_macos() then
          M.add_dir(full)
        end
        return
      end
      if not M.should_handle(p, ignore) then
        return
      end
      if st and st.type == "file" then
        tombstone_path(p)
        local q = require("organ.queue")
        q.enqueue_background(p)
      else
        -- File missing — start grace timer.
        schedule_delete(p)
      end
    end)
  end)
end

local walk_async = require("organ.walk").walk_async

local function start_poll(path)
  if not M._opts or not M._opts.use_polling then
    return
  end
  if M._pollers[path] then
    return
  end
  local p = vim.loop.new_fs_poll()
  local interval = M._opts.poll_interval_ms or 5000
  p:start(
    path,
    interval,
    vim.schedule_wrap(function(err, _prev, _curr)
      if err then
        return
      end
      local q = require("organ.queue")
      q.enqueue_background(path)
    end)
  )
  M._pollers[path] = p
end

local function maybe_start_poll(path)
  start_poll(path)
end

local function rescan_once()
  if not M._opts then
    return
  end
  local ignore = M._opts.ignore or {}
  local roots = {}
  for p in pairs(M._dirs) do
    roots[#roots + 1] = p
  end
  for _, root_dir in ipairs(roots) do
    walk_async(root_dir, M._opts.scan_batch_size or 50, function(subdir)
      -- Phase 2: ensure we have a watcher on subdirs.
      -- macOS: only watch symlinked subdirs explicitly (recursive FSEvents
      -- covers native subtrees but does not follow symlinks).
      if not is_macos() then
        M.add_dir(subdir)
      else
        -- FSEvents recursive mode does not follow symlinks, so we need an
        -- explicit watcher for any symlinked subdir, even when a recursive
        -- parent watcher already exists. Pass force=true to bypass the
        -- "covered by parent" guard in add_dir.
        local lst = vim.loop.fs_lstat(subdir)
        if lst and lst.type == "link" then
          M.add_dir(subdir, true)
        end
      end
    end, function(file, _st)
      -- Phase 3: enqueue any org file for mtime/hash check via should_skip.
      if M.should_handle(file, ignore) then
        require("organ.queue").enqueue_background(file)
        maybe_start_poll(file)
      end
    end, nil)
  end
end

local function start_rescan_timer()
  local interval = (M._opts and M._opts.rescan_interval_ms) or 60000
  if interval > 0 then
    M._rescan = vim.loop.new_timer()
    M._rescan:start(interval, interval, vim.schedule_wrap(rescan_once))
  end
  -- Always do at least one immediate Phase-2 discovery tick.
  -- This is needed for polling discovery even when the periodic timer is off.
  vim.schedule(rescan_once)
end

function M.start(opts, org_dir)
  -- Idempotent: a re-entry (e.g. user calls setup() twice, or vim.pack
  -- reloads plugin/* mid-session) MUST stop the previous handles before
  -- opening new ones. Without this, every fs_event fires twice (or N
  -- times for N setups).
  if next(M._dirs) ~= nil or M._rescan ~= nil then
    M.stop()
  end

  M._opts = opts or {}
  -- Phase 1: open one handle per top-level dir.
  if org_dir then
    M.add_dir(org_dir)
  end
  for _, d in ipairs(M._opts.watch_dirs or {}) do
    M.add_dir(d)
  end
  -- Phase 2/3: start the periodic safety-net rescan timer.
  start_rescan_timer()
end

function M.stop()
  for _, st in pairs(M._dirs) do
    pcall(function()
      st.handle:stop()
    end)
    pcall(function()
      st.handle:close()
    end)
  end
  M._dirs = {}
  for _, t in pairs(M._tombstones) do
    pcall(function()
      t:stop()
    end)
    pcall(function()
      t:close()
    end)
  end
  M._tombstones = {}
  if M._rescan then
    pcall(function()
      M._rescan:stop()
    end)
    pcall(function()
      M._rescan:close()
    end)
    M._rescan = nil
  end
  for _, p in pairs(M._pollers) do
    pcall(function()
      p:stop()
    end)
    pcall(function()
      p:close()
    end)
  end
  M._pollers = {}
  M._opts = nil
end

M.commands = {
  ["watch start"] = {
    fn = function()
      local bc = require("organ.buf_config")
      M.start(bc.read(nil, "watcher"), bc.read(nil, "org_dir"))
    end,
    desc = "Start the organ filesystem watcher",
  },
  ["watch stop"] = {
    fn = function()
      M.stop()
    end,
    desc = "Stop the organ filesystem watcher",
  },
  ["watch status"] = {
    fn = function()
      local dirs = M.watched_dirs()
      local pending = 0
      for _ in pairs(M._tombstones or {}) do
        pending = pending + 1
      end
      vim.api.nvim_echo({
        {
          string.format(
            "organ.watcher: %d dir(s) watched; %d pending tombstone(s)",
            #dirs,
            pending
          ),
          "None",
        },
      }, false, {})
    end,
    desc = "Show organ watcher status",
  },
}

return M
