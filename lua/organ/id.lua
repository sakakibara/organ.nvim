-- lua/organ/id.lua
-- :Org id get_create -- assign an :ID: (per `links.id_method`) to the
-- current headline's :PROPERTIES: drawer.  Matches Emacs M-x org-id-get-create.

local M = {}

-- Generate a fresh org id per the configured `links.id_method` (Emacs
-- `org-id-method`).  This is the single id source for every :ID: organ
-- creates -- headline ids and roam node / daily ids alike:
--   "uuid"   (default) -> RFC 9562 v7 (time-ordered)
--   "uuidv4"           -> RFC 4122 v4 random (Emacs org-id's default shape)
--   "ts"               -> "YYYYMMDDTHHMMSS-NNN"
--   function           -> user generator returning a non-empty string
function M.generate(bufnr)
  local method = (require("organ.buf_config").read(bufnr, "links") or {}).id_method or "uuid"
  if type(method) == "function" then
    local ok, v = pcall(method)
    if ok and type(v) == "string" and v ~= "" then
      return v
    end
  elseif method == "ts" then
    return os.date("%Y%m%dT%H%M%S") .. "-" .. string.format("%03d", math.random(0, 999))
  elseif method == "uuidv4" then
    return require("organ.uuid").v4()
  end
  return require("organ.uuid").v7()
end

-- Read the existing :ID: from the properties drawer of the headline at `line`.
-- Returns the ID string or nil if absent.
local function read_id(bufnr, line)
  local entries = require("organ.property").list(bufnr, line) or {}
  for _, e in ipairs(entries) do
    if e.key == "ID" then
      return e.value
    end
  end
  return nil
end

-- Public: read the :ID: of the headline at `line`, or nil if it has
-- none.  Non-mutating sibling of `get_or_create` — used by the
-- `id_link_policy = "use-existing"` path so `:Org store_link` can fall
-- back to a `file::*Headline` link when the headline is untagged.
function M.get(bufnr, line)
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return nil
  end
  return read_id(bufnr, hl.line)
end

-- Public: get or create the :ID: property on the headline containing `line`.
-- Notifies the user and returns the ID string (existing or new).
function M.get_or_create(bufnr, line)
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return nil
  end

  local existing = read_id(bufnr, hl.line)
  if existing then
    require("organ.notify").info("organ: ID already set: " .. existing)
    return existing
  end

  local new_id = M.generate(bufnr)
  local err = require("organ.property").set(bufnr, hl.line, "ID", new_id)
  if err then
    require("organ.notify").error(err)
    return nil
  end

  require("organ.notify").info("organ: ID created: " .. new_id)
  return new_id
end

-- Escape a string for embedding in an Emacs Lisp s-expression
-- string literal.  Identical rules as Lua's "%q" for ASCII printable
-- chars: backslash-escape `\` and `"`, and backslash-escape control
-- characters with their printable equivalent so a downstream
-- `read`-er recovers the original.
local function escape_elisp(s)
  return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
end

-- Public: export every (file, id) pair in the index to a file in
-- Emacs's `org-id-locations-file` format (s-expression alist).
-- Emacs's org-id loads it on startup so cross-file `[[id:...]]`
-- links resolve without a full org_dir scan.  Round-tripping
-- between Emacs and organ keeps both in sync if both are pointed at
-- the same file.
--
-- Format (matches `org-id-hash-to-alist`'s output):
--   ((FILEPATH ID1 ID2 ...) (FILEPATH ID3 ...))
function M.export_locations(target_path)
  target_path = target_path
    or (require("organ.buf_config").read(nil, "links") or {}).id_locations_file
  if not target_path or target_path == "" then
    return nil, "no id_locations_file configured"
  end
  target_path = vim.fn.expand(target_path)
  local h = require("organ.runtime").db()
  local db = require("organ.db")
  local stmt, perr = h:prepare([[
    SELECT file_path, id FROM headlines
    WHERE id IS NOT NULL AND id != ''
    ORDER BY file_path, line_start
  ]])
  if not stmt then
    return nil, "id export: db prepare failed: " .. tostring(perr)
  end
  local order = {}
  local by_file = {}
  while stmt:step() == db.SQLITE_ROW do
    local fp = stmt:column_text(0)
    local id = stmt:column_text(1)
    if not by_file[fp] then
      by_file[fp] = {}
      order[#order + 1] = fp
    end
    by_file[fp][#by_file[fp] + 1] = id
  end
  stmt:finalize()
  local out = { ";; -*- coding: utf-8 -*-", "(" }
  for _, fp in ipairs(order) do
    local ids = by_file[fp]
    local quoted = {}
    for _, id in ipairs(ids) do
      quoted[#quoted + 1] = escape_elisp(id)
    end
    out[#out + 1] = " (" .. escape_elisp(fp) .. " " .. table.concat(quoted, " ") .. ")"
  end
  out[#out + 1] = ")"
  out[#out + 1] = ""
  local body = table.concat(out, "\n")
  local ok, err = require("organ.path").write_atomic(target_path, body)
  if not ok then
    return nil, "id export: write failed: " .. tostring(err)
  end
  return target_path, #order
end

-- Auto-export hook: when `id_locations_file` is set, refresh it after
-- every successful scan so Emacs sees fresh ID locations on its next
-- load.  Wired from organ.init via the "scan_done" event so we don't
-- write on every individual file index.
function M._maybe_auto_export()
  local cfg = (require("organ.buf_config").read(nil, "links") or {})
  if not cfg.id_locations_file or cfg.id_locations_file == "" then
    return
  end
  local _, err = M.export_locations()
  if err and type(err) == "string" then
    require("organ.notify").warn(err)
  end
end

M.commands = {
  ["id get_create"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      M.get_or_create(bufnr, line)
    end,
    desc = "Assign UUID v7 :ID: to current headline if absent (Emacs org-id-get-create)",
  },
  ["id update"] = {
    fn = function()
      local organ = require("organ")
      if require("organ.buf_config").read(nil, "notify") then
        vim.schedule(function()
          require("organ.notify").info(
            "rescanning " .. require("organ.buf_config").read(nil, "org_dir")
          )
        end)
      end
      organ._start_scan()
      organ._scan_walk(require("organ.buf_config").read(nil, "org_dir"), function()
        if require("organ.buf_config").read(nil, "notify") then
          vim.schedule(function()
            require("organ.notify").info("ID locations refreshed")
          end)
        end
        organ._poll_scan_completion()
      end)
    end,
    desc = "Re-scan org_dir to refresh ID -> file:line index after files were moved/renamed",
  },
  ["id export_locations"] = {
    fn = function(cmd)
      local target = cmd and cmd.args ~= "" and cmd.args or nil
      local path, n = M.export_locations(target)
      if not path then
        require("organ.notify").error(tostring(n))
        return
      end
      require("organ.notify").info(("organ: wrote %d file group(s) to %s"):format(n or 0, path))
    end,
    nargs = "?",
    complete = "file",
    desc = "Export the ID index to an Emacs `org-id-locations-file` (s-expression alist)",
  },
}

return M
