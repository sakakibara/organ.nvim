-- lua/organ/runtime.lua
-- Singleton lazy accessors for runtime resources (SQLite handle, TS parser).
-- Each accessor opens-and-caches on first call. Subsequent calls are O(1).

local M = {}

local _db_handle = nil
local _parser_registered = false

-- Returns the SQLite handle, opening + applying schema on first call.
function M.db()
  if _db_handle then
    return _db_handle
  end
  local cfg = require("organ").config
  local db_mod = require("organ.db")
  local dir = vim.fn.fnamemodify(cfg.db_path, ":h")
  vim.fn.mkdir(dir, "p")
  local h, err, rc = db_mod.open(cfg.db_path, { pragmas = cfg.pragmas })
  if not h then
    local fatal = (
      rc == db_mod.SQLITE_CORRUPT
      or rc == db_mod.SQLITE_NOTADB
      or rc == db_mod.SQLITE_IOERR
      or (err and (err:match("not a database") or err:match("malformed") or err:match("disk I/O")))
    )
    if fatal and cfg.auto_recover then
      local bak = cfg.db_path .. ".corrupt." .. tostring(os.time())
      os.rename(cfg.db_path, bak)
      require("organ.notify").warn("organ: DB corruption detected; moved to " .. bak)
      h, err, rc = db_mod.open(cfg.db_path, { pragmas = cfg.pragmas })
    end
    if not h then
      error(
        ("organ: failed to open DB at %s: %s (rc=%s)"):format(
          cfg.db_path,
          tostring(err),
          tostring(rc)
        )
      )
    end
  end
  require("organ")._ensure_schema(h)
  h._organ_row_chunk = cfg.row_chunk
  _db_handle = h
  return h
end

-- Resolve the path to a built parser binary by probing, in order:
--   1. an explicit override (user-set `cfg.parser_path` for the block
--      grammar; for the inline grammar we derive a sibling path)
--   2. organ.nvim's own install dir (populated by
--      `lua/organ/grammar_install.lua`)
--   3. nvim-treesitter's parser dir (for users who installed via
--      `:TSInstall`)
local function resolve_parser(grammar, override_path)
  local candidates = {}
  if override_path and override_path ~= "" then
    candidates[#candidates + 1] = override_path
  end
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/organ/parser/" .. grammar
  local lang = grammar:match("^(.-)%.[^.]+$") or grammar
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/site/parser/" .. lang .. ".so"
  for _, p in ipairs(candidates) do
    if vim.uv.fs_stat(p) ~= nil then
      return p, candidates
    end
  end
  return nil, candidates
end

-- Canary input that exercises constructs unique to the
-- tree-sitter-organ AST shape (block-level): a TODO headline AND a
-- src_block. If the parser at the resolved path produces something
-- different, it's a different tree-sitter-Org grammar (cached from a
-- previous nvim-treesitter install of someone else's parser, say) and
-- organ.nvim's queries / indexer would silently break against it.
local CANARY = "* TODO foo\n\n#+begin_src lua\ntest\n#+end_src\n"

local function verify_organ_grammar(path)
  -- Register under a one-off language name so we can probe without
  -- touching the production "org" registration.
  -- nvim's language.add prefixes "tree_sitter_" to symbol_name, so we
  -- pass "org" → looks up tree_sitter_org in the .so.
  local probe_lang = "_organ_canary_" .. tostring(vim.uv.hrtime())
  local ok = pcall(vim.treesitter.language.add, probe_lang, { path = path, symbol_name = "org" })
  if not ok then
    return false, "dlopen failed (likely wrong arch)"
  end
  local parser = vim.treesitter.get_string_parser(CANARY, probe_lang)
  local trees = parser and parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return false, "parse() returned nothing"
  end
  local root = tree:root()
  if root:type() ~= "document" then
    return false, ("root node is `%s`, expected `document`"):format(root:type())
  end
  local saw_headline, saw_src_block = false, false
  local function walk(n)
    local ty = n:type()
    if ty == "headline" then
      saw_headline = true
    end
    if ty == "src_block" then
      saw_src_block = true
    end
    if saw_headline and saw_src_block then
      return
    end
    for i = 0, n:child_count() - 1 do
      walk(n:child(i))
      if saw_headline and saw_src_block then
        return
      end
    end
  end
  walk(root)
  if not saw_headline then
    return false, "no `headline` node"
  end
  if not saw_src_block then
    return false, "no `src_block` node"
  end
  return true
end

-- Registers the TS parser if not yet registered. Safe to call repeatedly.
-- On dlopen failure or canary mismatch, surface an actionable error
-- instead of silently using the wrong parser.
function M.parser()
  if _parser_registered then
    return
  end
  local cfg = require("organ").config
  local found, candidates = resolve_parser("org.so", cfg.parser_path)
  if not found then
    require("organ.notify").error(
      (
        "tree-sitter parser not installed. Tried:\n  %s\nRun your plugin manager's build hook, "
        .. "or :lua require('organ.grammar_install').install()"
      ):format(table.concat(candidates, "\n  "))
    )
    return
  end
  local ok_canary, err_canary = verify_organ_grammar(found)
  if not ok_canary then
    require("organ.notify").error(
      (
        "tree-sitter-org parser at\n  %s\nis NOT the tree-sitter-organ "
        .. "grammar organ.nvim requires (%s).\n"
        .. "This is usually a cached parser from a different tree-sitter-Org plugin.\n"
        .. "Reinstall the correct grammar: "
        .. ":lua require('organ.grammar_install').install()"
      ):format(found, err_canary)
    )
    return
  end
  local ok, err = pcall(vim.treesitter.language.add, "org", { path = found })
  if not ok then
    require("organ.notify").error(
      (
        "failed to load parser at %s.\n"
        .. "       Reason: %s\n"
        .. "       Rebuild: :lua require('organ.grammar_install').install()"
      ):format(found, tostring(err))
    )
    return
  end
  _parser_registered = true
end

-- Returns the handle only if it was already opened; never triggers lazy open.
function M.db_if_open()
  return _db_handle
end

-- For test cleanup / re-init scenarios.
function M.reset()
  if _db_handle and _db_handle.close then
    pcall(_db_handle.close, _db_handle)
  end
  _db_handle = nil
  _parser_registered = false
end

return M
