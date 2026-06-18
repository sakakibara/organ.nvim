-- :checkhealth organ support. Reports on:
--   - libsqlite3 loads successfully
--   - grammar/org.so is present
--   - DB is reachable and writable
--   - schema user_version matches what this plugin ships

local M = {}

local health = vim.health

-- Probe libsqlite3 via FFI. Returns the loaded db module, or nil when the
-- module fails to load (a hard stop for the rest of the report).
local function check_sqlite()
  local ok, db = pcall(require, "organ.db")
  if ok then
    health.ok("libsqlite3 loaded via FFI")
    return db
  end
  health.error("libsqlite3 failed to load: " .. tostring(db))
  return nil
end

-- Parser presence + dlopen verification (catches arch mismatches early).
local function check_parser()
  local parser = require("organ.buf_config").read(nil, "parser_path")
  local plat
  do
    local u = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
    plat = (u.sysname or "?"):lower() .. "-" .. (u.machine or "?")
  end
  health.info("platform: " .. plat)
  if not parser or not vim.loop.fs_stat(parser) then
    health.error(
      ("tree-sitter parser missing at %s — build for this host: `make -C grammar`"):format(
        tostring(parser)
      )
    )
  else
    local ok_load, err_load = pcall(vim.treesitter.language.add, "org", { path = parser })
    if ok_load then
      health.ok("tree-sitter parser loads: " .. parser)
    else
      health.error(
        ("tree-sitter parser at %s failed to dlopen for %s\n  reason: %s\n  fix: `make -C grammar` on this host (the binary was likely built for a different OS/arch)"):format(
          parser,
          plat,
          tostring(err_load)
        )
      )
    end
  end
end

-- DB + schema: trigger lazy open so we report the live schema version.
-- `db` is the module returned by check_sqlite (needed for db.SQLITE_ROW).
-- Returns false to signal check() should stop early.
local function check_db_and_schema(db)
  local db_path = require("organ.buf_config").read(nil, "db_path")
  if not db_path then
    health.error("db_path unset")
    return false
  end

  local rt = require("organ.runtime")
  local h_live, open_err = pcall(rt.db)
  if not h_live then
    health.error("db_path failed to open: " .. tostring(open_err))
    return false
  end
  local live_handle = rt.db_if_open()
  if not live_handle then
    health.error("runtime.db() returned nil after open attempt")
    return false
  end

  if vim.loop.fs_stat(db_path) then
    health.ok("database file exists at " .. db_path)
  else
    health.warn("database file missing at " .. db_path)
  end

  -- Probe schema version on the live handle (avoids a second open).
  local s, perr = live_handle:prepare("PRAGMA user_version")
  if not s then
    health.error("schema probe failed: " .. tostring(perr))
    return false
  end
  assert(s:step() == db.SQLITE_ROW)
  local v = s:column_int(0)
  s:finalize()
  if v == 1 then
    health.ok("schema user_version = 1 (current)")
  elseif v == 0 then
    health.warn("schema not yet applied (user_version=0)")
  else
    health.warn(("schema user_version = %d (newer than this build expects)"):format(v))
  end
  return true
end

local function check_watcher()
  local watcher_ok, w = pcall(require, "organ.watcher")
  if watcher_ok and w then
    local dirs = w.watched_dirs()
    if #dirs > 0 then
      health.ok(("watcher running, %d dir(s) watched"):format(#dirs))
    else
      health.warn("watcher idle (no dirs watched)")
    end
  else
    health.warn("watcher module not loadable")
  end
end

-- Optional plugin detection. organ degrades gracefully when these aren't
-- installed, but several features only light up when the right host
-- plugin is available; this section tells the user what's wired in their
-- current session.
local function check_optional_integrations()
  health.start("organ optional integrations")

  -- Picker backends.
  local has_snacks = (_G.Snacks and _G.Snacks.picker) or (pcall(require, "snacks.picker"))
  local has_telescope = pcall(require, "telescope.pickers")
  local has_fzf_lua = pcall(require, "fzf-lua")
  local cfg_backend = (require("organ.buf_config").read(nil, "find") or {}).backend or "snacks"
  if has_snacks then
    health.ok("snacks.nvim loaded — :Org find, :Org roam, completion picker available")
  else
    health.info("snacks.nvim not loaded")
  end
  if has_telescope then
    health.ok("telescope.nvim loaded — usable as find.backend")
  else
    health.info("telescope.nvim not loaded")
  end
  if has_fzf_lua then
    health.ok("fzf-lua loaded — usable as find.backend")
  else
    health.info("fzf-lua not loaded")
  end
  if cfg_backend == "auto" then
    health.info("find.backend = 'auto' (autodetect: snacks → telescope → fzf-lua)")
  else
    local has_configured = ({
      snacks = has_snacks,
      telescope = has_telescope,
      fzf_lua = has_fzf_lua,
    })[cfg_backend]
    if has_configured then
      health.ok(("find.backend = '%s' is loaded"):format(cfg_backend))
    else
      health.warn(
        ("find.backend = '%s' is configured but the plugin isn't loaded — :Org find will fail"):format(
          cfg_backend
        )
      )
    end
  end

  -- Completion adapters.
  local has_blink = pcall(require, "blink.cmp")
  local has_cmp = pcall(require, "cmp")
  if has_blink then
    health.ok(
      "blink.cmp loaded — `organ_link` (and `organ_drawer` / `organ_roam_node` when enabled) sources registered"
    )
  else
    health.info("blink.cmp not loaded")
  end
  if has_cmp then
    health.ok("nvim-cmp loaded — same source set as blink")
  else
    health.info("nvim-cmp not loaded")
  end

  -- which-key (auto-registration of the keymap registry).
  local has_wk = pcall(require, "which-key")
  if has_wk then
    health.ok("which-key.nvim loaded — :Org keymap groups auto-registered")
  else
    health.info("which-key.nvim not loaded (key-discoverability falls back to native :map)")
  end

  -- Inline image renderer.
  local has_image = pcall(require, "image")
  if has_image then
    health.ok(
      "image.nvim loaded — :Org image_reveal / :Org toggle_inline_images render in-buffer"
    )
  else
    health.info("image.nvim not loaded — image links open in the system viewer instead")
  end
end

-- which-key + alarms surface a quick summary of opt-in features the user
-- has turned on. Helps spot common misconfigurations.
local function check_feature_toggles(cfg)
  health.start("organ feature toggles")
  local function status(name, on)
    if on then
      health.ok(name .. " = on")
    else
      health.info(name .. " = off")
    end
  end
  status("agenda.include_diary_sexp", (cfg.agenda or {}).include_diary_sexp == true)
  status("alarms.enabled", (cfg.alarms or {}).enabled == true)
  status("attach.git", (cfg.attach or {}).git == true)
  status("babel.confirm_evaluate", (cfg.babel or {}).confirm_evaluate ~= false)
  status("complete.roam_everywhere", (cfg.complete or {}).roam_everywhere == true)
  status("entities (pretty)", (cfg.entities or {}).enabled == true)
  status("indent", (cfg.indent or {}).enabled == true)
  status("links.allow_unsafe", (cfg.links or {}).allow_unsafe == true)
  status("speed", (cfg.speed or {}).enabled == true)
  status("tags.inherit", (cfg.tags or {}).inherit ~= false)
end

local function check_startup()
  -- Sanity check: did plugin/organ.lua actually load?
  -- If it did, vim.g.loaded_organ is true. If false at this point, the
  -- user has lazy-loaded organ and the :Org* commands aren't registered.
  health.start("organ startup")
  if vim.g.loaded_organ then
    health.ok("plugin/organ.lua loaded at startup (commands registered)")
  else
    health.warn(
      "plugin/organ.lua has NOT been sourced — :Org* commands aren't registered.\n"
        .. "  Most likely cause: lazy.nvim defers the plugin via `lazy = true` / `event = ...` / `ft = ...`.\n"
        .. "  Fix: set `lazy = false` in your spec (the plugin/organ.lua file is intentionally cheap; ~5 ms)."
        .. " The DB and parser stay lazy regardless."
    )
  end

  -- Useful contextual info.
  if vim.fn.executable("git") == 1 then
    health.ok("git on PATH (required for attach.git)")
  else
    health.info("git NOT on PATH — attach.git will no-op")
  end
  if vim.fn.executable("curl") == 1 or vim.fn.executable("wget") == 1 then
    health.ok("curl/wget on PATH (required for :Org attach url)")
  else
    health.info("neither curl nor wget on PATH — :Org attach url will fail")
  end
end

-- Live session state for the modules that maintain runtime objects
-- across calls — surfaces timer running, sessions count, sticky
-- agenda buffers, profiler running, modern stages attached.
local function check_session_state()
  health.start("organ session state")
  do
    local timer_ok, timer = pcall(require, "organ.timer")
    if timer_ok then
      local s = timer.status()
      if s.status then
        health.ok(
          ("timer %s: %d s remaining (of %d s)"):format(
            s.status,
            s.remaining or 0,
            s.duration_s or 0
          )
        )
      else
        health.info("timer: not running")
      end
    end

    local prof_ok, prof = pcall(require, "organ.profile")
    if prof_ok then
      if prof.is_enabled() then
        health.ok("profiler: recording (slow ≥ " .. tostring(prof._slow_ms) .. " ms)")
      else
        health.info("profiler: idle")
      end
    end

    local sess_ok, sess = pcall(require, "organ.babel.sessions")
    if sess_ok then
      local list = sess.list()
      if #list > 0 then
        local names = {}
        for _, e in ipairs(list) do
          names[#names + 1] = e.key
        end
        health.ok(("babel sessions alive (%d): %s"):format(#list, table.concat(names, ", ")))
      else
        health.info("babel sessions: none alive")
      end
    end

    local agenda_ok, agenda = pcall(require, "organ.agenda")
    if agenda_ok and agenda._sticky then
      local n = 0
      for _ in pairs(agenda._sticky) do
        n = n + 1
      end
      if n > 0 then
        health.ok(("sticky agenda buffers: %d"):format(n))
      else
        health.info("sticky agenda buffers: none")
      end
    end

    -- Modern stages: detect by namespace presence on the current buffer.
    local cur_buf = vim.api.nvim_get_current_buf()
    if vim.bo[cur_buf].filetype == "org" then
      local ns_map = vim.api.nvim_get_namespaces()
      local function has_ns_marks(ns_name)
        local ns = ns_map[ns_name]
        if not ns then
          return false
        end
        local m = vim.api.nvim_buf_get_extmarks(cur_buf, ns, 0, -1, { limit = 1 })
        return #m > 0
      end
      local on = {}
      if has_ns_marks("organ_modern_bullets") then
        on[#on + 1] = "bullets"
      end
      if has_ns_marks("organ_modern_blocks") then
        on[#on + 1] = "blocks"
      end
      if has_ns_marks("organ_modern_pills") then
        on[#on + 1] = "pills"
      end
      if has_ns_marks("organ_stars_hide") then
        on[#on + 1] = "stars-hide"
      end
      if has_ns_marks("organ_indent") then
        on[#on + 1] = "indent"
      end
      if #on > 0 then
        health.ok("visual stages attached on this buffer: " .. table.concat(on, ", "))
      else
        health.info("no visual stages attached on the current org buffer")
      end
    end
  end
end

-- Native CSL processor probe. The processor is pure Lua, so the only
-- thing to verify is that vim.json is reachable (Neovim 0.10+) since
-- the CSL-JSON parser depends on it.
local function check_citation_processor()
  health.start("organ citation processor")
  if vim and vim.json and vim.json.decode then
    health.ok("vim.json available — CSL-JSON parser usable")
  else
    health.warn("vim.json missing — CSL-JSON parsing will fail (BibTeX still works)")
  end
  -- If a buffer is current and has #+bibliography directives, surface
  -- their resolution status for quick diagnosis.
  local cur = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(cur) and vim.bo[cur].filetype == "org" then
    local lines = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
    local cite = require("organ.cite")
    local paths = cite.find_bibliographies(table.concat(lines, "\n"))
    if #paths > 0 then
      local buf_name = vim.api.nvim_buf_get_name(cur)
      local buf_dir = (buf_name ~= "") and vim.fs.dirname(buf_name) or nil
      for _, p in ipairs(paths) do
        local full = vim.fn.fnamemodify(p, ":p")
        if full == "" or not vim.uv.fs_stat(full) then
          full = buf_dir and vim.fs.joinpath(buf_dir, p) or p
        end
        if vim.uv.fs_stat(full) then
          health.ok("bibliography resolves: " .. p .. " → " .. full)
        else
          health.error("bibliography NOT FOUND: " .. p)
        end
      end
    else
      health.info("no #+bibliography: directives in current buffer")
    end
  end
end

-- User-config integration: when the user runs a custom foldtext or
-- custom statuscolumn, those override organ's win-local set and
-- silently strip the Emacs-style folded heading / fold-aware relnum
-- unless they delegate.  Detect the common shapes and surface a
-- warning with a one-line fix.
local function check_user_config_integration()
  health.start("organ.user-config integration")

  local function references(s, ...)
    if not s or s == "" then
      return false
    end
    for _, pat in ipairs({ ... }) do
      if s:find(pat, 1, true) then
        return true
      end
    end
    return false
  end

  local function is_lua_wrapper(s)
    -- `v:lua.<...>` or `%!v:lua.<...>` -- custom Lua function whose
    -- delegation we can't see from the option string alone.
    return s:find("v:lua%.") ~= nil
  end

  local foldtext = vim.o.foldtext
  local cfg_fold = require("organ.buf_config").read(nil, "fold") or {}
  if cfg_fold.auto_foldtext == true then
    health.ok(
      "foldtext: auto-apply on (organ sets win-local 'foldtext' + drops `·` fold filler on org buffers)"
    )
  elseif foldtext == "" or foldtext == "foldtext()" then
    health.warn(
      "foldtext is at vim default and auto_foldtext is off; org folds will render `+--  N lines:`",
      {
        "Easiest fix: set fold.auto_foldtext = true (or leave it at the default).",
        "Or wire your global foldtext to delegate when filetype == 'org':",
        "    function MyFoldtext()",
        "      if vim.bo.filetype == 'org' then",
        "        local ok, fold = pcall(require, 'organ.fold')",
        "        if ok then return fold.foldtext() end",
        "      end",
        "      return vim.fn.foldtext()",
        "    end",
        "    vim.opt.foldtext = 'v:lua.MyFoldtext()'",
        "See |organ-config-fold-foldtext| / |organ-config-fold-auto_foldtext|.",
      }
    )
  elseif references(foldtext, "organ.fold", "organ_fold") then
    health.ok("foldtext references organ.fold")
  elseif is_lua_wrapper(foldtext) then
    health.info(
      "Custom Lua foldtext: "
        .. foldtext
        .. ".  If your wrapper "
        .. "delegates to organ.fold.foldtext when filetype == 'org', "
        .. "fold rendering is correct.  Otherwise folded headings "
        .. "render plain.  See |organ-config-fold-foldtext|."
    )
  else
    health.warn(
      "Custom global foldtext is set but doesn't reference organ.fold."
        .. "  Org buffers may render plain folded headings instead of"
        .. " the Emacs-style colored line. Current value:\n    "
        .. foldtext,
      {
        "See `:h organ-config-fold-foldtext` for the renderer contract.",
        "Recipe: have your custom foldtext delegate when filetype == 'org':",
        "    if vim.bo.filetype == 'org' then",
        "      local ok, organ_fold = pcall(require, 'organ.fold')",
        "      if ok and organ_fold.foldtext then return organ_fold.foldtext() end",
        "    end",
      }
    )
  end

  local statuscolumn = vim.o.statuscolumn
  if cfg_fold.auto_statuscolumn == true then
    health.ok("statuscolumn: auto-apply on (organ sets win-local 'statuscolumn' for org buffers)")
  elseif statuscolumn == "" then
    health.ok("statuscolumn: vim default")
  elseif
    references(statuscolumn, "statuscolumn_marker", "organ.fold")
    and references(statuscolumn, "statuscolumn_lnum", "organ.fold.contents")
  then
    health.ok("statuscolumn references both organ helpers")
  elseif is_lua_wrapper(statuscolumn) then
    health.info(
      "Custom Lua statuscolumn: "
        .. statuscolumn
        .. ".  If your "
        .. "wrapper calls organ.fold.statuscolumn_marker and "
        .. "organ.fold.contents.statuscolumn_lnum, fold markers and "
        .. "relnum render correctly.  Otherwise sibling headings may "
        .. "show no fold marker and concealed-body rows may inflate "
        .. "relnum.  See |organ-fold-statuscolumn_marker| for a recipe."
    )
  else
    local missing = {}
    if not references(statuscolumn, "statuscolumn_marker") then
      missing[#missing + 1] = "statuscolumn_marker (heading fold-start indicator)"
    end
    if not references(statuscolumn, "statuscolumn_lnum") then
      missing[#missing + 1] = "statuscolumn_lnum (visible-line relnum)"
    end
    health.warn(
      "Custom statuscolumn is set but doesn't reference: "
        .. table.concat(missing, ", ")
        .. ".  Sibling headings may render no fold marker, and "
        .. "concealed-body rows may inflate relnum.",
      {
        "See `:h organ-fold-statuscolumn_marker` for a complete recipe",
        "wiring both helpers into a custom statuscolumn module.",
      }
    )
  end
end

function M.check()
  local organ = require("organ")

  local db = check_sqlite()
  if not db then
    return
  end

  check_parser()

  if not check_db_and_schema(db) then
    return
  end

  check_watcher()
  check_optional_integrations()
  check_feature_toggles(organ.config)
  check_startup()
  check_session_state()
  check_citation_processor()
  check_user_config_integration()
end

return M
