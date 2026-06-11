-- Insert-mode link completion for organ.nvim.

local M = {}

local obuf = require("organ.buf")
M.TRIGGERS = {
  ["[[id:"] = "id",
  ["[[*"] = "headline",
  ["[[file:"] = "file",
  ["[[attachment:"] = "attachment",
}

function M.trigger_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local prefix_part = line:sub(1, col)

  local open_at = prefix_part:find("%[%[[^%[]*$")
  if not open_at then
    return nil
  end

  local payload = prefix_part:sub(open_at)
  for trigger, kind in pairs(M.TRIGGERS) do
    if payload:sub(1, #trigger) == trigger then
      local rest = payload:sub(#trigger + 1)
      if rest:find("]]", 1, true) then
        return nil
      end
      return {
        kind = kind,
        prefix = trigger,
        prefix_col = open_at - 1,
        query = rest,
      }
    end
  end

  -- Property-value trigger: [[<KEY>: where KEY is property-name shaped
  -- and not a reserved scheme.
  local key, rest = payload:match("^%[%[([A-Za-z][A-Za-z0-9_-]*):(.*)$")
  if key then
    local reserved = {
      id = true,
      file = true,
      attachment = true,
      http = true,
      https = true,
      mailto = true,
    }
    if not reserved[key] and not rest:find("]]", 1, true) then
      return {
        kind = "property_value",
        key = key,
        prefix = "[[" .. key .. ":",
        prefix_col = open_at - 1,
        query = rest,
      }
    end
  end

  return nil
end

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return require("organ.buf_config").read(nil, "complete") or {}
end

local function relpath(p)
  return vim.fn.fnamemodify(p, ":.")
end

-- Walk a directory recursively, collecting up to `cap` file paths whose
-- relative form contains `query` (substring; case-insensitive).
local function walk_files(root_dir, query, cap)
  local results = {}
  local q_lower = (query or ""):lower()
  local function visit(d)
    if #results >= cap then
      return
    end
    local h = vim.uv.fs_scandir(d)
    if not h then
      return
    end
    while true do
      if #results >= cap then
        return
      end
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      if not name:match("^%.") then
        local full = d .. "/" .. name
        if t == "directory" then
          visit(full)
        elseif t == "file" then
          local rel = relpath(full)
          if q_lower == "" or rel:lower():find(q_lower, 1, true) then
            results[#results + 1] = rel
          end
        end
      end
    end
  end
  pcall(visit, root_dir)
  return results
end

-- Build completion items from a list of relative file paths.
local function file_items(paths)
  local items = {}
  for _, p in ipairs(paths) do
    items[#items + 1] = {
      kind = "file",
      display = p,
      insert_text = p,
      description = vim.fn.fnamemodify(p, ":t"),
    }
  end
  return items
end

local function list_dir(dir, query)
  local results = {}
  local q_lower = (query or ""):lower()
  local h = vim.uv.fs_scandir(dir)
  if not h then
    return results
  end
  while true do
    local name, t = vim.uv.fs_scandir_next(h)
    if not name then
      break
    end
    if t == "file" then
      if q_lower == "" or name:lower():find(q_lower, 1, true) then
        results[#results + 1] = name
      end
    end
  end
  return results
end

function M.items_for(kind, query)
  local query_cap = get_config().query_max_results or 500
  if kind == "id" then
    local rows = require("organ.query").headlines({ has_id = true, limit = query_cap })
    local items = {}
    for _, r in ipairs(rows) do
      items[#items + 1] = {
        kind = "id",
        display = string.format(
          "%s   %s:%d",
          r.title,
          relpath(r.file_path),
          (r.line_start or 0) + 1
        ),
        insert_text = r.id,
        description = r.title,
      }
    end
    return items
  end

  if kind == "headline" then
    local rows = require("organ.query").headlines({ limit = query_cap })
    local items = {}
    for _, r in ipairs(rows) do
      items[#items + 1] = {
        kind = "headline",
        display = string.format(
          "%s   %s:%d",
          r.title,
          relpath(r.file_path),
          (r.line_start or 0) + 1
        ),
        insert_text = r.title,
        description = r.title,
      }
    end
    return items
  end

  if kind == "file" then
    -- Synchronous walk; used by the omnifunc path (Vim completion must
    -- return items synchronously). The snacks-picker path walks
    -- asynchronously via open_picker so it never blocks the keystroke.
    local cfg = get_config()
    local cap = cfg.file_walk_max_results or 500
    return file_items(walk_files(vim.fn.getcwd(), query, cap))
  end

  if kind == "attachment" then
    local cfg = get_config()
    local dir = cfg.attachment_dir or (vim.fn.getcwd() .. "/attachments")
    local names = list_dir(dir, query)
    local items = {}
    for _, n in ipairs(names) do
      items[#items + 1] = {
        kind = "attachment",
        display = n,
        insert_text = n,
        description = n,
      }
    end
    return items
  end

  if kind == "property_value" then
    -- For property_value, the second argument is the full trigger table
    -- (we need both key and query), not just the query string.
    local trigger = query
    if type(trigger) ~= "table" or not trigger.key then
      return {}
    end

    local rows = require("organ.query").headlines({
      has_property = trigger.key,
      include_properties = true,
      limit = query_cap,
    })
    local items = {}
    local seen = {}
    for _, r in ipairs(rows) do
      local raw = (r.properties or {})[trigger.key]
      if raw then
        for tok in raw:gmatch("%S+") do
          if
            tok ~= ""
            and not seen[tok]
            and (trigger.query == "" or tok:find(trigger.query, 1, true))
          then
            seen[tok] = true
            items[#items + 1] = {
              kind = "property_value",
              insert_text = tok,
              display = tok .. "   →  " .. (r.title or ""),
              description = r.title,
            }
          end
        end
      end
    end
    return items
  end

  return {}
end

M._open_for = {}

-- Entries the async file walk processes per event-loop yield.
local FILE_WALK_BATCH = 256

local function show_picker(bufnr, trigger, items)
  local picker_items = {}
  for _, it in ipairs(items) do
    picker_items[#picker_items + 1] = {
      display = it.display,
      match_fields = { "display" },
      _item = it,
    }
  end
  require("organ.find").pick({
    source = "complete",
    items = picker_items,
    default_action = "complete_select",
    actions = {
      complete_select = function(picker_item)
        M.apply_selection(bufnr, trigger, picker_item._item)
      end,
    },
  })
end

-- Recursively collect matching files asynchronously (walk_async, the same
-- cooperative walker the indexer uses), then open the picker from on_done.
-- The keystroke returns immediately; the fs walk never blocks the UI.
-- `dedupe_key` is the maybe_open guard key for this position; clear it if
-- the walk aborts so the same position can re-trigger, but only when no
-- newer trigger has replaced it.
local function open_file_picker_async(bufnr, trigger, dedupe_key)
  local cfg = get_config()
  local cap = cfg.file_walk_max_results or 500
  local root = vim.fn.getcwd()
  local q_lower = (trigger.query or ""):lower()
  local paths = {}
  require("organ.walk").walk_async(root, FILE_WALK_BATCH, nil, function(full, _st)
    if #paths >= cap then
      return
    end
    local rel = relpath(full)
    if q_lower == "" or rel:lower():find(q_lower, 1, true) then
      paths[#paths + 1] = rel
    end
  end, function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- The cursor may have moved while we walked; only open the picker if
    -- the same file trigger is still active at the same position.
    local fresh = M.trigger_at_cursor(bufnr)
    if not fresh or fresh.kind ~= "file" or fresh.prefix_col ~= trigger.prefix_col then
      if M._open_for[bufnr] == dedupe_key then
        M._open_for[bufnr] = nil
      end
      return
    end
    show_picker(bufnr, fresh, file_items(paths))
  end)
end

function M.open_picker(bufnr, trigger, dedupe_key)
  if trigger.kind == "file" then
    open_file_picker_async(bufnr, trigger, dedupe_key)
    return
  end
  local items
  if trigger.kind == "property_value" then
    items = M.items_for(trigger.kind, trigger)
  else
    items = M.items_for(trigger.kind, trigger.query)
  end
  show_picker(bufnr, trigger, items)
end

-- True when a host completion plugin is already loaded; we then skip the
-- snacks-picker fallback so users don't see two UIs at once. Progressive
-- enhancement: blink.cmp / nvim-cmp own the popup if present.
local function host_completion_active()
  if package.loaded["blink.cmp"] then
    return true
  end
  if package.loaded["cmp"] then
    return true
  end
  return false
end

function M.maybe_open(bufnr)
  if host_completion_active() then
    return
  end
  local trigger = M.trigger_at_cursor(bufnr)
  if not trigger then
    M._open_for[bufnr] = nil
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local key = row .. ":" .. trigger.prefix_col
  if M._open_for[bufnr] == key then
    return
  end
  M._open_for[bufnr] = key

  M.open_picker(bufnr, trigger, key)
end

-- Debounced entry for the TextChangedI autocmd: rapid keystrokes collapse
-- to a single maybe_open after complete.debounce_ms of quiet, so no
-- completion work runs on the per-keystroke path.
local _debounced_open
function M.schedule_open(bufnr)
  if not _debounced_open then
    local ms = get_config().debounce_ms or 150
    _debounced_open = require("organ.debounce").trailing(ms, function(b)
      M.maybe_open(b)
    end)
  end
  _debounced_open(bufnr)
end

function M.apply_selection(bufnr, trigger, item)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local fresh = M.trigger_at_cursor(bufnr)
  if not fresh or fresh.prefix ~= trigger.prefix or fresh.prefix_col ~= trigger.prefix_col then
    require("organ.notify").warn("completion target moved; aborting insert")
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local link = string.format("%s%s][%s]]", trigger.prefix, item.insert_text, item.description)
  local ok, err = pcall(obuf.set_text, bufnr, row, trigger.prefix_col, row, col, { link })
  if not ok then
    require("organ.notify").warn("organ: completion failed: " .. tostring(err))
    return
  end
  vim.api.nvim_win_set_cursor(0, { row + 1, trigger.prefix_col + #link })
end

-- Omnifunc adapter — fires for users without blink.cmp / nvim-cmp who
-- use Vim's built-in `<C-x><C-o>` completion.  Two-phase per
-- `:h complete-functions`:
--   * findstart=1: locate the trigger column (col of `[[id:` etc.)
--   * findstart=0: return the candidate list
--
-- Wired automatically in ftplugin/org.lua via `vim.bo.omnifunc`.
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  if findstart == 1 then
    local trigger = M.trigger_at_cursor(bufnr)
    if not trigger then
      return -3 -- "cancel completion silently"
    end
    -- Stash the trigger so phase 2 can reuse it (avoid re-parsing the
    -- line from the now-shifted cursor position).
    M._omni_trigger = trigger
    -- omnifunc reports the byte column where the matched text starts;
    -- we want completion to replace the text AFTER the prefix, so
    -- point at the column right after `[[id:` (or whichever trigger).
    return trigger.prefix_col + #trigger.prefix
  end
  local trigger = M._omni_trigger
  M._omni_trigger = nil
  if not trigger then
    return {}
  end
  local items = M.items_for(trigger.kind, base or trigger.query or "")
  local out = {}
  for _, it in ipairs(items or {}) do
    out[#out + 1] = {
      word = it.insert_text,
      abbr = it.display,
      menu = "[organ:" .. trigger.kind .. "]",
      info = it.description,
    }
  end
  return out
end

M.commands = {
  complete = {
    fn = function()
      M.maybe_open(vim.api.nvim_get_current_buf())
    end,
    desc = "Open the link completion picker for the `[[...` trigger at cursor",
  },
}

return M
