-- Download + build the tree-sitter-organ and tree-sitter-organ-inline
-- grammars into `stdpath("data")/organ/parser/`.
--
-- Designed to run from a plugin-manager build hook (lazy.nvim's `build`,
-- paq's `build`, mini.deps' `hooks.post_install`). Works with or without
-- nvim-treesitter installed.
--
-- Layout under stdpath("data")/organ/:
--
--   src/
--     tree-sitter-organ/         <- git clone
--     tree-sitter-organ-inline/  <- git clone
--   parser/
--     org.so
--     org_inline.so
--
-- The `parser/` directory uses Neovim's standard tree-sitter parser
-- discovery layout: at startup, plugin/organ.lua prepends the parent
-- (stdpath("data")/organ) onto runtimepath, so Neovim auto-discovers
-- the parsers without needing explicit vim.treesitter.language.add()
-- calls.
--
-- One-binary-per-machine; matches nvim-treesitter's convention. Users
-- syncing the data dir across heterogenous machines should re-run the
-- build hook on each.

local M = {}

local REPO_BLOCK = "https://github.com/sakakibara/tree-sitter-organ"
local REPO_INLINE = "https://github.com/sakakibara/tree-sitter-organ-inline"

-- Local platform fragment used only to locate the build artifact inside
-- each grammar's `build/` directory (the upstream Makefile is per-arch).
-- We don't expose this in our install layout.
local function _platform_triple()
  if jit and jit.os and jit.arch then
    local os_name = jit.os:lower()
    local arch = jit.arch:lower()
    if os_name == "osx" then
      os_name = "darwin"
    end
    if arch == "x64" then
      arch = "x86_64"
    end
    if arch == "arm64" and os_name == "linux" then
      arch = "aarch64"
    end
    return os_name .. "-" .. arch
  end
  local u = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
  return (u.sysname or "unknown"):lower() .. "-" .. (u.machine or "unknown")
end

-- Progress lines go to a log file (and stdout when running headless via
-- `nvim --headless`). They are NOT routed through `vim.notify` because
-- without a notification UI plugin (noice / nvim-notify / mini.notify),
-- each notify call piles up in the message area and triggers a
-- "Press ENTER" prompt. The user gets ONE notify at the very end via
-- `summary_notify`; that's the only press-enter event.
local function log_path()
  local dir = (vim.fn and vim.fn.stdpath and vim.fn.stdpath("data") or "/tmp") .. "/organ"
  return dir .. "/grammar-install.log"
end

local _log_lines = {}

-- True iff this nvim has no UI attached (i.e. invoked via
-- `nvim --headless`). `has("gui_running")` is the WRONG check — it's
-- only true for true GUIs (Neovide etc.); ordinary terminal nvim
-- reports 0 too. We need to NOT stream to stdout in terminal nvim
-- because plugin managers (lazy / vim.pack) capture our stdout and
-- surface it as floating messages in the user's editor.
local function _is_headless()
  if vim and vim.api and vim.api.nvim_list_uis then
    return #vim.api.nvim_list_uis() == 0
  end
  return false
end

local function progress(msg)
  _log_lines[#_log_lines + 1] = os.date("%Y-%m-%dT%H:%M:%S") .. " " .. msg
  -- Stream to stdout ONLY when truly headless (a CI script / one-off
  -- `nvim --headless -l ...` invocation). Terminal nvim stays silent;
  -- the user gets the single end-of-install summary notify instead.
  if _is_headless() then
    io.write("organ: " .. msg .. "\n")
    io.flush()
  end
end

-- vim.fn.mkdir() fails when another Neovim creates the directory first.
local function mkdir_p(dir)
  pcall(vim.fn.mkdir, dir, "p")
end

local function flush_log()
  if #_log_lines == 0 then
    return
  end
  if vim and vim.fn and vim.fn.stdpath then
    mkdir_p(vim.fn.stdpath("data") .. "/organ")
  end
  local fd = io.open(log_path(), "a")
  if fd then
    for _, line in ipairs(_log_lines) do
      fd:write(line .. "\n")
    end
    fd:close()
  end
  _log_lines = {}
end

local function summary_notify(msg, level)
  flush_log()
  if vim and vim.notify then
    vim.notify("organ: " .. msg, level or vim.log.levels.INFO)
  else
    (level == vim.log.levels.ERROR and io.stderr or io.stdout):write("organ: " .. msg .. "\n")
  end
end

local RETRY_CMD = ":Org install_grammars"

-- One WARN per failed install: what failed and the first line of why,
-- with the full error going to the log only.  A multi-line notify of
-- make's whole output is what gets lost in a plugin manager's build
-- window.
local function notify_err(what, err)
  local msg = what .. ": " .. err
  progress("ERROR: " .. msg)
  flush_log()
  local short = ("%s: %s\nlog: %s\nretry: %s"):format(
    what,
    (err:match("^[^\n]*")),
    log_path(),
    RETRY_CMD
  )
  if vim and vim.notify then
    vim.notify("organ: " .. short, vim.log.levels.WARN)
  else
    io.stderr:write("organ: " .. short .. "\n")
  end
end

-- Coroutines started by install_async().  system() yields only inside
-- one of these; any other caller -- including a plugin manager whose
-- build task is itself a coroutine -- blocks on :wait() as before.
local _async = {}
local _running = false
-- Any install this session, by hand or by the build hook, spends the
-- automatic retry: rerunning the same build moments later fails the
-- same way.
local _retried = false

-- Bounds a hung clone or build, which would otherwise hold the install
-- lock for the rest of the session.
M._timeout_ms = 5 * 60 * 1000

-- vim.system's own timeout signals only the direct child, and its result
-- waits for the pipes: a grandchild holding them open (git's https helper
-- on a stalled connection) delays it indefinitely.
M._grace_ms = 10 * 1000
local TIMED_OUT = { code = 124, signal = 9, stdout = "", stderr = "" }

-- Running commands, killed when Neovim exits so no build outlives it.
local _procs = {}
local _exit_hooked = false
local function track(proc)
  if not _exit_hooked then
    _exit_hooked = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        for p in pairs(_procs) do
          pcall(p.kill, p, 9)
        end
        M._unlock()
      end,
    })
  end
  _procs[proc] = true
end

local function system(cmd, opts)
  opts = vim.tbl_extend("keep", opts, { timeout = M._timeout_ms })
  local co = coroutine.running()
  if co and _async[co] then
    local proc, timer
    local settled = false
    local function settle(res)
      if settled then
        return
      end
      settled = true
      timer:close()
      _procs[proc] = nil
      _async[co].resume(res)
    end
    proc = vim.system(cmd, opts, function(res)
      vim.schedule(function()
        settle(res)
      end)
    end)
    track(proc)
    timer = assert(vim.uv.new_timer())
    timer:start(
      opts.timeout + M._grace_ms,
      0,
      vim.schedule_wrap(function()
        pcall(proc.kill, proc, 9)
        settle(TIMED_OUT)
      end)
    )
    return coroutine.yield()
  end
  local proc = vim.system(cmd, opts)
  track(proc)
  local res = proc:wait(opts.timeout + M._grace_ms)
  _procs[proc] = nil
  return res or TIMED_OUT
end

-- Waits inside a background install without blocking the UI.
local function sleep(ms)
  local co = coroutine.running()
  vim.defer_fn(function()
    _async[co].resume()
  end, ms)
  coroutine.yield()
end

-- Another Neovim building into the same clones would `git clean` under
-- this one's make.  The lock file holds the owner's pid; a dead owner's
-- lock is stale, and so is one older than any install can take, which
-- covers a reused pid and an owner on another host sharing the dir.
local LOCK_WAIT_MS = 20 * 60 * 1000
local LOCK_STALE_S = 30 * 60
local _locked = false

local function lock_path()
  return vim.fn.stdpath("data") .. "/organ/install.lock"
end

local function read_pid(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local pid = tonumber(f:read("*a"))
  f:close()
  return pid
end

-- EPERM means another user's process, which is not this user's Neovim.
local function alive(pid)
  if not pid or pid == vim.uv.os_getpid() then
    return false
  end
  return vim.uv.kill(pid, 0) == 0
end

-- Pid of the live Neovim holding the lock at `path`, or nil.
local function holder(path)
  local pid = read_pid(path)
  local st = vim.uv.fs_stat(path)
  if not (st and alive(pid)) or os.time() - st.mtime.sec > LOCK_STALE_S then
    return nil
  end
  return pid
end

-- The lock appears complete or not at all: the pid is written to a
-- private file first and hard-linked into place, which fails if the
-- lock exists.
local function try_lock()
  local path = lock_path()
  mkdir_p(vim.fn.fnamemodify(path, ":h"))
  local mine = path .. "." .. vim.uv.os_getpid()
  local fd = vim.uv.fs_open(mine, "w", 420)
  if not fd then
    return false
  end
  vim.uv.fs_write(fd, tostring(vim.uv.os_getpid()))
  vim.uv.fs_close(fd)
  local ok = vim.uv.fs_link(mine, path)
  if not ok then
    local stale = read_pid(path)
    -- Rename is atomic, so one breaker wins; a breaker that grabbed a
    -- fresh lock instead of the stale one puts it back.
    local grabbed = path .. ".stale." .. vim.uv.os_getpid()
    if not holder(path) and vim.uv.fs_rename(path, grabbed) then
      if read_pid(grabbed) ~= stale then
        vim.uv.fs_link(grabbed, path)
      end
      os.remove(grabbed)
      ok = vim.uv.fs_link(mine, path)
    end
  end
  os.remove(mine)
  _locked = ok == true
  return _locked
end

function M._unlock()
  if _locked then
    _locked = false
    os.remove(lock_path())
  end
end

local function run(cmd, cwd)
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end
  local res = system(cmd, opts)
  if res.code == 124 and (res.signal or 0) ~= 0 then
    return false, ("%s timed out after %gs"):format(table.concat(cmd, " "), M._timeout_ms / 1000)
  end
  if res.code ~= 0 then
    return false,
      string.format(
        "%s exited %d\nstdout:\n%s\nstderr:\n%s",
        table.concat(cmd, " "),
        res.code,
        res.stdout or "",
        res.stderr or ""
      )
  end
  return true
end

-- Current checked-out commit of a git working tree, or nil if `dir`
-- isn't a clone / git is unavailable.  Best-effort: callers treat nil
-- as "can't tell" and stay quiet.
local function git_head(dir)
  local res = system({ "git", "-C", dir, "rev-parse", "HEAD" }, { text = true })
  if res.code ~= 0 then
    return nil
  end
  return (res.stdout or ""):gsub("%s+$", "")
end

local function manifest_path()
  return vim.fn.stdpath("data") .. "/organ/parser/.build-manifest.json"
end

local function clone_or_pull(url, dest)
  -- Case 1: dest is a managed git clone — hard-sync to remote tip.
  -- This is a managed clone (organ owns the directory, not the user),
  -- so we hard-sync rather than `pull --ff-only`.  That handles:
  --   1. Untracked generated files (`src/tree_sitter/*.h`,
  --      `src/parser.c`) that overlap paths now tracked upstream —
  --      this is exactly what bites users who installed before the
  --      headers were committed to the grammar repos.
  --   2. Local tracked-file edits (e.g. accidental save into the
  --      install dir) that would otherwise turn a fast-forward into
  --      a 3-way merge.
  --   3. History rewinds upstream (rare, but `--ff-only` would fail).
  -- A fresh `clean -fdx` afterwards drops `node_modules/`, `build/`
  -- etc. so the next `make` step regenerates them deterministically.
  if vim.fn.isdirectory(dest .. "/.git") == 1 then
    -- Verify the remote points at the URL we expect.  If a prior
    -- install used a different URL (e.g. user reconfigured a fork),
    -- the safest move is to blow it away and reclone — otherwise
    -- `fetch origin HEAD` would pull the WRONG tree.
    local res = system({ "git", "-C", dest, "remote", "get-url", "origin" }, { text = true })
    local current_url = (res.stdout or ""):gsub("%s+$", "")
    if res.code == 0 and current_url == url then
      progress("updating " .. vim.fn.fnamemodify(dest, ":t"))
      local ok, err = run({ "git", "-C", dest, "fetch", "--quiet", "--depth=1", "origin", "HEAD" })
      if not ok then
        return false, err
      end
      ok, err = run({ "git", "-C", dest, "reset", "--hard", "--quiet", "FETCH_HEAD" })
      if not ok then
        return false, err
      end
      return run({ "git", "-C", dest, "clean", "-fdxq" })
    end
    progress(
      string.format(
        "remote mismatch in %s (got %s, want %s); reinstalling",
        vim.fn.fnamemodify(dest, ":t"),
        current_url ~= "" and current_url or "<unknown>",
        url
      )
    )
    vim.fn.delete(dest, "rf")
  elseif vim.fn.isdirectory(dest) == 1 then
    -- Case 2: dest exists but has NO `.git` — almost always the
    -- residue of a previous failed `git clone` (or a partial unzip).
    -- `git clone` refuses to write into a non-empty directory, so
    -- we'd loop forever.  Wipe and start clean.
    progress("removing partial " .. vim.fn.fnamemodify(dest, ":t") .. " (no .git found)")
    vim.fn.delete(dest, "rf")
  end

  -- Case 3: fresh clone.
  progress("cloning " .. url)
  return run({ "git", "clone", "--depth=1", "--quiet", url, dest })
end

local function build_grammar(src_dir)
  -- The grammar repos commit `src/parser.c` + `src/tree_sitter/*.h`
  -- so end users don't need tree-sitter-cli (= no Node / pnpm dep).
  -- Plain `make` runs the C compile against the committed sources.
  -- Maintainers regenerate parser.c after grammar.js edits via the
  -- repo's Makefile target `make generate`; that pull does need
  -- npm but it's an upstream concern, not a user concern.
  progress("running make in " .. vim.fn.fnamemodify(src_dir, ":t"))
  return run({ "make" }, src_dir)
end

-- Install a freshly-built parser at `dst`.  Two macOS landmines to
-- avoid (and they show up the same way on Linux when something else
-- caches inodes):
--
--   1. The destination must keep its executable bit so dlopen accepts
--      it.  io.open(dst, "wb") creates with default umask (0644),
--      stripping +x.
--   2. The destination must end up at a FRESH inode.  io.open(dst,
--      "wb") truncates in place, which keeps the inode but rewrites
--      the bytes -- macOS Sequoia's code-signing path caches signature
--      validity by inode, so the next dlopen sees stale-cache vs new-
--      bytes and the kernel SIGKILLs nvim with "Code Signature
--      Invalid" before any error message can be shown.  Symptom is
--      "nvim crashes on first .org buffer after a grammar update".
--
-- fs_copyfile preserves the source's mode bits, then fs_rename swaps
-- the temp file in atomically -- guaranteed new inode, no half-written
-- file ever visible at the destination path.
local function copy_artifact(src, dst)
  local dir = vim.fn.fnamemodify(dst, ":h")
  vim.fn.mkdir(dir, "p")
  if vim.uv.fs_stat(src) == nil then
    return false, "missing build output: " .. src
  end
  local tmp = dst .. ".tmp." .. tostring(vim.uv.os_getpid())
  local ok, err = vim.uv.fs_copyfile(src, tmp)
  if not ok then
    return false, "copyfile " .. src .. " -> " .. tmp .. ": " .. tostring(err)
  end
  ok, err = vim.uv.fs_rename(tmp, dst)
  if not ok then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "rename " .. tmp .. " -> " .. dst .. ": " .. tostring(err)
  end
  -- macOS only: ad-hoc-sign the replaced .so.  When a previously-loaded
  -- code-signed mach-O is replaced in place, the kernel's CodeSigning
  -- subsystem still has the OLD signature cached by path -- the next
  -- process that tries to map a page from the file sees the cached
  -- signature vs new mtime, marks the page invalid, and SIGKILLs the
  -- process before any error can be reported.  Re-signing with the
  -- ad-hoc cert (`-`) refreshes the cache so a subsequent nvim load
  -- succeeds.  `vim.loop.os_uname().sysname == "Darwin"` is the right
  -- guard; on Linux / other Unixes this is a no-op and `codesign` is
  -- usually absent anyway.
  if vim.uv.os_uname().sysname == "Darwin" and vim.fn.executable("codesign") == 1 then
    -- Synchronous even in a background install, so the caller can place
    -- both parsers without yielding between them.  It takes milliseconds;
    -- the bound is tight because the UI waits on it.
    local res = vim
      .system({ "codesign", "--force", "--sign", "-", dst }, { text = true, timeout = 30000 })
      :wait() or TIMED_OUT
    if res.code ~= 0 then
      return false, "codesign failed for " .. dst .. ": " .. (res.stderr or "")
    end
  end
  return true
end

local GRAMMAR_REPOS = "tree-sitter-organ + tree-sitter-organ-inline"

-- opts.restart_hint: the summary asks for a restart (see needs_restart).
-- opts.for_missing: started because grammars were missing, so another
-- Neovim's install that supplied them makes this one unnecessary.
local function install(opts)
  opts = opts or {}
  if not try_lock() then
    if not _async[coroutine.running() or false] then
      local pid = holder(lock_path())
      vim.notify(
        ("organ: grammar install not started: %s holds %s"):format(
          pid and ("Neovim pid " .. pid) or "another install",
          lock_path()
        ),
        vim.log.levels.WARN
      )
      return false, "install already running"
    end
    vim.notify("organ: waiting for another Neovim's grammar install", vim.log.levels.INFO)
    local waited = 0
    repeat
      if waited >= LOCK_WAIT_MS then
        notify_err(GRAMMAR_REPOS .. " not built", "another Neovim's install never finished")
        return false, "lock wait timed out"
      end
      sleep(1000)
      waited = waited + 1000
    until try_lock()
    if opts.for_missing and #M.missing() == 0 then
      summary_notify("grammars installed by another Neovim")
      return true
    end
  end
  if vim.fn.executable("git") ~= 1 then
    notify_err(GRAMMAR_REPOS .. " not fetched", "git not in PATH")
    return false, "git missing"
  end
  if vim.fn.executable("make") ~= 1 then
    notify_err(GRAMMAR_REPOS .. " not built", "make not in PATH")
    return false, "make missing"
  end

  local data_root = vim.fn.stdpath("data") .. "/organ"
  local parser_dir = data_root .. "/parser"
  local plat = _platform_triple()
  local src_root = data_root .. "/src"

  vim.fn.mkdir(src_root, "p")
  vim.fn.mkdir(parser_dir, "p")

  -- Records the source revision each parser was BUILT from, keyed by
  -- grammar file.  Written only after a fully successful install, so a
  -- later `check_stale()` can tell "installed parser is behind the
  -- source clone" -- which is exactly what happens when a subsequent
  -- update pulls a new grammar revision but its build fails.
  local manifest = {}
  local built = {}
  local failed

  for _, grammar in ipairs({
    {
      url = REPO_BLOCK,
      dir_name = "tree-sitter-organ",
      built = "build/" .. plat .. "/org.so",
      file = "org.so",
      out = parser_dir .. "/org.so",
    },
    {
      url = REPO_INLINE,
      dir_name = "tree-sitter-organ-inline",
      built = "build/" .. plat .. "/org_inline.so",
      file = "org_inline.so",
      out = parser_dir .. "/org_inline.so",
    },
  }) do
    local src_dir = src_root .. "/" .. grammar.dir_name
    local ok, err = clone_or_pull(grammar.url, src_dir)
    if not ok then
      notify_err(grammar.dir_name .. " clone failed", err)
      failed = err
      break
    end
    ok, err = build_grammar(src_dir)
    if not ok then
      notify_err(grammar.dir_name .. " build failed", err)
      failed = err
      break
    end
    grammar.src_dir = src_dir
    built[#built + 1] = grammar
  end

  -- Place the parsers back to back, after every build and without
  -- yielding between them: a session that parses org with org.so but not
  -- yet org_inline.so caches the inline parser as missing.
  for _, grammar in ipairs(built) do
    local ok, err = copy_artifact(grammar.src_dir .. "/" .. grammar.built, grammar.out)
    if not ok then
      notify_err(grammar.dir_name .. " install failed", err)
      return false, err
    end
    progress("installed " .. grammar.dir_name .. " → " .. grammar.out)
  end
  if failed then
    return false, failed
  end
  for _, grammar in ipairs(built) do
    manifest[grammar.file] = { repo = grammar.dir_name, rev = git_head(grammar.src_dir) }
  end

  do
    local fd = io.open(manifest_path(), "w")
    if fd then
      fd:write(vim.json.encode(manifest))
      fd:close()
    end
  end

  progress("grammars ready under " .. data_root)
  -- ONE notify at the end (the only press-ENTER prompt the user sees on
  -- install / update). Per-step progress lives in the log file
  -- (`<stdpath data>/organ/grammar-install.log`) for users who want to
  -- inspect what happened.
  summary_notify(
    "grammars installed (org.so + org_inline.so)"
      .. (opts.restart_hint and "; restart Neovim to load them" or "")
  )
  return true
end

-- Rebuilding grammars that are present and loaded: Neovim never reloads
-- a language, so the old org.so stays in use.
local function needs_restart()
  if #M.missing() > 0 then
    return false
  end
  return vim._ts_has_language("org")
end

-- Reparse an org buffer with its injections; true when it has inline
-- content but still no org_inline tree.
local function inline_unresolved(buf)
  local parser = vim.treesitter.get_parser(buf, "org", { error = false })
  if not parser then
    return false
  end
  parser:invalidate(true)
  parser:parse(true)
  if parser:children().org_inline then
    return false
  end
  local query = vim.treesitter.query.get("org", "injections")
  local tree = parser:trees()[1]
  if not (query and tree) then
    return false
  end
  for _, _, meta in query:iter_matches(tree:root(), buf) do
    if meta["injection.language"] == "org_inline" then
      return true
    end
  end
  return false
end

-- Install both parsers. Returns (true) on full success, (false, err) on
-- the first failure. Idempotent — re-running fast-forwards the clones
-- and rebuilds.
function M.install()
  if _running then
    -- Not through notify_err: the running install owns the log.
    vim.notify(
      "organ: grammar install not started: another install is still running",
      vim.log.levels.WARN
    )
    return false, "install already running"
  end
  _running = true
  _retried = true
  local ok, res, err = pcall(install, { restart_hint = needs_restart() })
  _running = false
  M._unlock()
  if not ok then
    error(res, 0)
  end
  return res, err
end

-- Warn once per session when an installed parser is older than the
-- source revision the build hook last fetched.  `clone_or_pull` advances
-- the source clone to the new tip BEFORE building, so a failed build
-- leaves the clone ahead of the still-old parser -- a silent, indefinite
-- degradation (the user runs a month-old grammar and never knows).  This
-- turns that into a visible, actionable prompt, using only local git
-- (no network): the build manifest's recorded revision vs the clone's
-- current HEAD.
--
-- Silent no-op when there's nothing to compare: no manifest (installed
-- before this existed, or via a prebuilt/nvim-treesitter path), no source
-- clone, or git unavailable.
local _stale_warned = false
function M.check_stale()
  if _stale_warned then
    return
  end
  local ok = pcall(function()
    local fd = io.open(manifest_path(), "r")
    if not fd then
      return
    end
    local raw = fd:read("*a")
    fd:close()
    local ok_json, manifest = pcall(vim.json.decode, raw)
    if not ok_json or type(manifest) ~= "table" then
      return
    end
    local src_root = vim.fn.stdpath("data") .. "/organ/src"
    local stale = {}
    for file, entry in pairs(manifest) do
      if type(entry) == "table" and entry.repo and entry.rev then
        local head = git_head(src_root .. "/" .. entry.repo)
        if head and head ~= entry.rev then
          stale[#stale + 1] = file
        end
      end
    end
    if #stale > 0 then
      _stale_warned = true
      table.sort(stale)
      summary_notify(
        ("%s out of date -- a grammar update fetched a newer revision but its build did not complete. "):format(
          table.concat(stale, " + ")
        )
          .. "Rebuild with `"
          .. RETRY_CMD
          .. "`. Full log: "
          .. log_path(),
        vim.log.levels.WARN
      )
    end
  end)
  return ok
end

-- Run install() without blocking the UI: every external command yields
-- the coroutine until its process exits.  When it ends, start tree-sitter
-- on the org buffers that opened without it.  `on_done(ok, err)` fires
-- when the install finishes.  Returns false, without starting anything,
-- while an earlier call is still running.
function M.install_async(on_done)
  if _running then
    return false
  end
  _running = true
  _retried = true
  local missing = M.missing()
  local inline_missing = vim.tbl_contains(missing, "org_inline.so")
  local opts = { restart_hint = needs_restart(), for_missing = #missing > 0 }
  local co = coroutine.create(install)
  local function finish(ok, err)
    _running = false
    _async[co] = nil
    M._unlock()
    -- Even a failed install may have placed org.so (the inline build
    -- failing after it), which still beats the bundled syntax.
    --
    -- The first dlopen of a freshly signed parser is slow on macOS.  Left
    -- to the highlighter, it lands inside an async parse step, and a step
    -- that overruns 'redrawtime' leaves the highlighter waiting forever.
    local org_ok, org_err = pcall(vim.treesitter.language.add, "org")
    local inline_ok, inline_err = pcall(vim.treesitter.language.add, "org_inline")
    -- Neovim caches "no parser" for an injected language in a weak table,
    -- so an org buffer parsed before org_inline existed keeps its inline
    -- markup plain until a collection drops the entry.
    if ok and inline_missing then
      collectgarbage()
    end
    local reparse = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "org" then
        if vim.treesitter.highlighter.active[buf] then
          reparse[#reparse + 1] = buf
        else
          local started, start_err = M.start_highlighter(buf)
          -- Built but unloadable (an ABI this Neovim lacks, say).  A
          -- failed build has already warned.
          if ok and not started then
            M.warn_fallback(start_err)
          end
        end
      end
    end
    if ok and not org_ok then
      M.warn_fallback(org_err)
    elseif ok and not inline_ok then
      M.warn_inline(inline_err)
    elseif ok and inline_missing then
      local stuck = false
      for _, buf in ipairs(reparse) do
        local checked, unresolved = pcall(inline_unresolved, buf)
        stuck = (checked and unresolved) or stuck
      end
      if stuck then
        vim.notify(
          "organ: org_inline.so installed; restart Neovim for inline highlighting",
          vim.log.levels.WARN
        )
      end
    end
    if on_done then
      on_done(ok, err)
    end
  end
  _async[co] = {
    resume = function(...)
      local ok, res, err = coroutine.resume(co, ...)
      if not ok then
        notify_err("grammar install aborted", tostring(res))
        finish(false, res)
      elseif coroutine.status(co) == "dead" then
        finish(res, err)
      end
    end,
  }
  vim.schedule(function()
    _async[co].resume(opts)
  end)
  return true
end

-- Start tree-sitter highlighting on an org buffer and drop the bundled
-- syntax/org.vim, whose `~...~` region bleeds to EOF on property values
-- like `:DIR: ~/path`.  vim.treesitter.start() stops syntax from loading
-- later but does not unload what already loaded.  Returns pcall's
-- (ok, err).
function M.start_highlighter(bufnr)
  local ok, err = pcall(vim.treesitter.start, bufnr, "org")
  if ok then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("syntax clear")
    end)
  end
  return ok, err
end

-- Grammar files no candidate location provides (see M.resolve).
function M.missing()
  local organ_ok, organ = pcall(require, "organ")
  local override = organ_ok and organ.config and organ.config.parser_path or nil
  local out = {}
  for _, grammar in ipairs({ "org.so", "org_inline.so" }) do
    local found = false
    for _, p in ipairs(M.resolve(grammar, grammar == "org.so" and override or nil)) do
      if vim.uv.fs_stat(p) ~= nil then
        found = true
        break
      end
    end
    if not found then
      out[#out + 1] = grammar
    end
  end
  return out
end

-- Called when an org buffer opens.  When a grammar is missing, start one
-- background install per session -- a build hook that failed (no
-- compiler yet, an unaccepted Xcode license) never runs again on its
-- own.  Returns true when a grammar is missing, so the caller knows the
-- install path owns the reporting.
function M.ensure()
  local missing = M.missing()
  if #missing == 0 then
    return false
  end
  if not _retried then
    vim.notify(
      ("organ: %s missing; building in the background"):format(table.concat(missing, " + ")),
      vim.log.levels.INFO
    )
    M.install_async()
  end
  return true
end

-- Warn, once per session, that highlighting failed although both
-- grammars are present (a parser built for another OS/arch, say).
local _fallback_warned = false
function M.warn_fallback(err)
  if _fallback_warned then
    return
  end
  _fallback_warned = true
  vim.notify(
    "organ: tree-sitter highlighting failed; falling back to Neovim's bundled "
      .. "syntax/org.vim, which has a known bleed bug.\n"
      .. ("rebuild: %s\n(detail: %s)"):format(RETRY_CMD, tostring(err)),
    vim.log.levels.WARN
  )
end

-- Warn, once per session, that org_inline.so is present but will not
-- load: the block grammar still highlights, so nothing else would say
-- why emphasis, links and timestamps stay plain.
local _inline_warned = false
function M.warn_inline(err)
  if _inline_warned then
    return
  end
  _inline_warned = true
  vim.notify(
    "organ: org_inline.so failed to load; inline markup stays unhighlighted.\n"
      .. ("rebuild: %s\n(detail: %s)"):format(RETRY_CMD, tostring(err)),
    vim.log.levels.WARN
  )
end

-- Resolve a parser path under the data dir. Returns the path string
-- and a boolean indicating whether the file exists.
function M.parser_path(grammar)
  local p = vim.fn.stdpath("data") .. "/organ/parser/" .. grammar
  return p, vim.uv.fs_stat(p) ~= nil
end

-- Best-effort path probe. Returns a list of candidate parser paths in
-- preference order:
--   1. cfg.parser_path (if user has overridden it)
--   2. organ's data-dir install (this module's output)
--   3. nvim-treesitter's parser dir, when the plugin is loaded
function M.resolve(grammar, override_path)
  local out = {}
  if override_path and override_path ~= "" then
    out[#out + 1] = override_path
  end
  out[#out + 1] = (M.parser_path(grammar))
  -- nvim-treesitter integration: it stores parsers under
  -- `stdpath("data")/site/parser/<lang>.so`. The language name here
  -- maps to the grammar filename without extension.
  local lang = grammar:match("^(.-)%.[^.]+$") or grammar
  out[#out + 1] = vim.fn.stdpath("data") .. "/site/parser/" .. lang .. ".so"
  return out
end

M.log_path = log_path

-- Exposed for tests; the only call sites stay inside this module.
M._copy_artifact = copy_artifact
M._platform_triple = _platform_triple

return M
