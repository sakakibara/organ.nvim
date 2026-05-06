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

local function flush_log()
  if #_log_lines == 0 then
    return
  end
  if vim and vim.fn and vim.fn.stdpath then
    vim.fn.mkdir(vim.fn.stdpath("data") .. "/organ", "p")
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

-- Errors are surfaced eagerly via vim.notify because they're rare,
-- actionable, and the user needs to know something failed before
-- dismissing further press-ENTER prompts. Each error also lands in the
-- log — we flush eagerly here so a hard early return from install()
-- still leaves a diagnosable trace on disk.
local function notify_err(msg)
  progress("ERROR: " .. msg)
  flush_log()
  if vim and vim.notify then
    vim.notify("organ: " .. msg .. "\n(full log: " .. log_path() .. ")", vim.log.levels.ERROR)
  else
    io.stderr:write("organ: " .. msg .. "\n")
  end
end

local function run(cmd, cwd)
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end
  local res = vim.system(cmd, opts):wait()
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
    local res = vim
      .system({ "git", "-C", dest, "remote", "get-url", "origin" }, { text = true })
      :wait()
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
  return true
end

-- Install both parsers. Returns (true) on full success, (false, err) on
-- the first failure. Idempotent — re-running fast-forwards the clones
-- and rebuilds.
function M.install()
  if vim.fn.executable("git") ~= 1 then
    notify_err("git not in PATH; cannot fetch grammars")
    return false, "git missing"
  end
  if vim.fn.executable("make") ~= 1 then
    notify_err("make not in PATH; cannot build grammars")
    return false, "make missing"
  end
  if vim.fn.executable("npm") ~= 1 and vim.fn.executable("pnpm") ~= 1 then
    notify_err("npm/pnpm not in PATH; needed for tree-sitter-cli")
    return false, "no node package manager"
  end

  local data_root = vim.fn.stdpath("data") .. "/organ"
  local parser_dir = data_root .. "/parser"
  local plat = _platform_triple()
  local src_root = data_root .. "/src"

  vim.fn.mkdir(src_root, "p")
  vim.fn.mkdir(parser_dir, "p")

  for _, grammar in ipairs({
    {
      url = REPO_BLOCK,
      dir_name = "tree-sitter-organ",
      built = "build/" .. plat .. "/org.so",
      out = parser_dir .. "/org.so",
    },
    {
      url = REPO_INLINE,
      dir_name = "tree-sitter-organ-inline",
      built = "build/" .. plat .. "/org_inline.so",
      out = parser_dir .. "/org_inline.so",
    },
  }) do
    local src_dir = src_root .. "/" .. grammar.dir_name
    local ok, err = clone_or_pull(grammar.url, src_dir)
    if not ok then
      notify_err(grammar.dir_name .. " clone failed: " .. err)
      return false, err
    end
    ok, err = build_grammar(src_dir)
    if not ok then
      notify_err(grammar.dir_name .. " build failed: " .. err)
      return false, err
    end
    ok, err = copy_artifact(src_dir .. "/" .. grammar.built, grammar.out)
    if not ok then
      notify_err(grammar.dir_name .. " install failed: " .. err)
      return false, err
    end
    progress("installed " .. grammar.dir_name .. " → " .. grammar.out)
  end

  progress("grammars ready under " .. data_root)
  -- ONE notify at the end (the only press-ENTER prompt the user sees on
  -- install / update). Per-step progress lives in the log file
  -- (`<stdpath data>/organ/grammar-install.log`) for users who want to
  -- inspect what happened.
  summary_notify("grammars installed (org.so + org_inline.so under " .. data_root .. ")")
  return true
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

-- Exposed for tests; the only call site stays inside this module.
M._copy_artifact = copy_artifact

return M
