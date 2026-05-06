-- Find-family picker dispatch for organ.nvim.

local M = {}

local function format_path(p, line_start)
  -- :~:. abbreviates with ~ for $HOME and prefers a relative form against cwd
  -- when applicable. line_start is 0-based; display 1-based for user familiarity.
  return vim.fn.fnamemodify(p, ":~:.") .. ":" .. tostring(line_start + 1)
end

local renderers = {
  level = function(r)
    return string.rep("*", r.level or 0)
  end,
  todo = function(r)
    return r.todo_state and string.format("%-5s", r.todo_state) or ""
  end,
  priority = function(r)
    return r.priority and ("[#" .. r.priority .. "]") or ""
  end,
  title = function(r)
    return r.title or ""
  end,
  tags = function(r)
    if not r.tags or #r.tags == 0 then
      return ""
    end
    return ":" .. table.concat(r.tags, ":") .. ":"
  end,
  path = function(r)
    return format_path(r.file_path, r.line_start or 0)
  end,
  backlinks = function(r)
    if not r.backlink_count or r.backlink_count == 0 then
      return ""
    end
    return string.format("(%s%d)", "\xe2\x86\x90", r.backlink_count) -- ← (UTF-8)
  end,
  -- Outline-path breadcrumb: file/ancestor1/ancestor2/… (Emacs's
  -- `org-refile-use-outline-path = 'file` format).  Disambiguates
  -- same-titled headings under different parents -- the common
  -- refile pain.  Computed in build_items via parent_id chain.
  breadcrumb = function(r)
    if not r.olp or #r.olp == 0 then
      return r.file_path and vim.fn.fnamemodify(r.file_path, ":t") or ""
    end
    local file = r.file_path and vim.fn.fnamemodify(r.file_path, ":t") or "?"
    return file .. "/" .. table.concat(r.olp, "/")
  end,
}

-- Per-column highlight resolver. Returns an hl group name (string) or
-- nil for unstyled. Some columns (todo, priority, level) need to look
-- at the record to pick a per-value group; others have a fixed group.
local function hl_for(col, record)
  if col == "level" then
    local lvl = record.level or 0
    if lvl >= 1 and lvl <= 8 then
      return "@org.heading." .. lvl
    end
    return "@org.heading.8"
  elseif col == "todo" then
    if record.todo_state then
      return "@organ.agenda.todo_" .. record.todo_state:lower()
    end
  elseif col == "priority" then
    if record.priority then
      return "@organ.agenda.priority_" .. record.priority
    end
  elseif col == "title" then
    return "@organ.find.title"
  elseif col == "tags" then
    return "@organ.agenda.tag"
  elseif col == "path" then
    return "@organ.find.path"
  elseif col == "backlinks" then
    return "@organ.find.backlinks"
  end
  return nil
end

function M.format_columns(record, columns)
  local parts = {}
  for _, col in ipairs(columns or {}) do
    local fn = renderers[col]
    if fn then
      local v = fn(record)
      if v ~= "" then
        parts[#parts + 1] = v
      end
    end
  end
  return table.concat(parts, " ")
end

-- Segment form: returns a list of { text, hl_group } pairs, with " "
-- separator segments interleaved. Backends that support per-segment
-- highlighting (snacks) use this directly; telescope adapts via
-- format_columns_with_ranges below; fzf-lua via format_columns_ansi.
function M.format_columns_segments(record, columns)
  local segs = {}
  for _, col in ipairs(columns or {}) do
    local fn = renderers[col]
    if fn then
      local v = fn(record)
      if v ~= "" then
        if #segs > 0 then
          segs[#segs + 1] = { " " }
        end
        segs[#segs + 1] = { v, hl_for(col, record) }
      end
    end
  end
  return segs
end

-- Telescope shape: takes the segment list and returns
-- (display_string, highlights) where highlights is a list of
-- { { start_byte, end_byte }, hl_group } with byte offsets into
-- display_string.  Telescope's entry_display accepts this tuple
-- from a `display` function.
function M.segments_to_ranges(segments)
  local parts, ranges = {}, {}
  local pos = 0
  for _, seg in ipairs(segments or {}) do
    local text, hl = seg[1], seg[2]
    parts[#parts + 1] = text
    if hl then
      ranges[#ranges + 1] = { { pos, pos + #text }, hl }
    end
    pos = pos + #text
  end
  return table.concat(parts), ranges
end

-- Fzf-lua shape: each segment is wrapped in an ANSI escape derived
-- from the highlight group's foreground color so fzf renders colors
-- when invoked with `--ansi`.  Returns the assembled string and a
-- boolean indicating whether ANSI wrapping actually happened (false
-- when fzf-lua's utility module isn't loadable -- callers can then
-- skip the `--ansi` fzf flag for cleanliness).
function M.segments_to_ansi(segments)
  local ok, fzf_utils = pcall(require, "fzf-lua.utils")
  local can_ansi = ok and type(fzf_utils.ansi_from_hl) == "function"
  local parts = {}
  for _, seg in ipairs(segments or {}) do
    local text, hl = seg[1], seg[2]
    if hl and can_ansi then
      local wrapped = fzf_utils.ansi_from_hl(hl, text)
      parts[#parts + 1] = wrapped or text
    else
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts), can_ansi
end

-- Auto-detect a loaded picker plugin.  Order: snacks → telescope →
-- fzf-lua → vim_ui_select.  Always returns a usable backend name
-- (vim_ui_select is built-in, requires no external plugin), so
-- callers don't need to handle "no picker available".
local function autodetect_backend()
  if package.loaded["snacks.picker"] or _G.Snacks then
    return "snacks"
  end
  if package.loaded["telescope"] or package.loaded["telescope.pickers"] then
    return "telescope"
  end
  if package.loaded["fzf-lua"] then
    return "fzf_lua"
  end
  return "vim_ui_select"
end

local function resolve_backend(spec)
  if type(spec) == "function" then
    return {
      pick = function(items, opts)
        spec(items, opts)
      end,
    }
  end
  if type(spec) == "string" then
    if spec == "_test_stub" then
      return require("organ.find.backend")._test_stub
    end
    if spec == "auto" then
      return require("organ.find.backends." .. autodetect_backend())
    end
    return require("organ.find.backends." .. spec)
  end
  error("find.pick: invalid backend spec: " .. tostring(spec))
end

M._autodetect_backend = autodetect_backend

-- Build a parent_id → row index for OLP computation. O(N) once per pick,
-- then each ancestor lookup is O(1).
local function build_id_index(rows)
  local idx = {}
  for _, r in ipairs(rows) do
    if r.id then
      idx[r.id] = r
    end
  end
  return idx
end

-- Walk parent_id chain and return the ordered ancestor titles (root
-- first, parent last; row's own title is NOT included).
local function compute_olp(r, id_index)
  local olp = {}
  local seen = {}
  local pid = r.parent_id
  while pid and not seen[pid] do
    seen[pid] = true
    local p = id_index[pid]
    if not p then
      break
    end
    table.insert(olp, 1, p.title or "?")
    pid = p.parent_id
  end
  return olp
end

local function build_items(rows, columns, match_fields)
  -- Pre-build the id index when any column needs OLP. Most picker
  -- callers don't request "breadcrumb"; skip the work in that case.
  local need_olp = false
  for _, c in ipairs(columns or {}) do
    if c == "breadcrumb" then
      need_olp = true
      break
    end
  end
  local id_index = need_olp and build_id_index(rows) or nil

  local items = {}
  for _, r in ipairs(rows) do
    if need_olp then
      r.olp = compute_olp(r, id_index)
    end
    items[#items + 1] = {
      id = r.id,
      title = r.title,
      file_path = r.file_path,
      line_start = r.line_start,
      level = r.level,
      todo_state = r.todo_state,
      priority = r.priority,
      tags = r.tags or {},
      olp = r.olp,
      backlink_count = r.backlink_count or 0,
      display = M.format_columns(r, columns),
      display_segments = M.format_columns_segments(r, columns),
      match_fields = match_fields,
    }
  end
  return items
end

local function build_link_items(rows, _columns, match_fields)
  local items = {}
  for _, r in ipairs(rows) do
    items[#items + 1] = {
      id = r.source_headline_id,
      source = r.source_headline,
      target_type = r.target_type,
      target = r.target,
      description = r.description,
      line = r.line,
      target_headline = r.target_headline,
      file_path = r.source_headline.file_path,
      line_start = (r.line or 1) - 1,
      level = r.source_headline.level,
      title = r.source_headline.title,
      todo_state = nil,
      priority = nil,
      tags = {},
      display = M.format_link(r),
      display_segments = M.format_link_segments(r),
      match_fields = match_fields,
    }
  end
  return items
end

-- Standard actions installed for every pick. insert_link / refile_here are
-- added by their command callbacks because they need the captured ctx.
local function standard_actions()
  return {
    jump = function(item)
      if item.kind == "file" then
        vim.cmd("edit " .. vim.fn.fnameescape(item.file_path))
        return
      end
      vim.cmd("edit " .. vim.fn.fnameescape(item.file_path))
      vim.api.nvim_win_set_cursor(0, { item.line_start + 1, 0 })
    end,
    split = function(item)
      if item.kind == "file" then
        vim.cmd("split " .. vim.fn.fnameescape(item.file_path))
        return
      end
      vim.cmd("split " .. vim.fn.fnameescape(item.file_path))
      vim.api.nvim_win_set_cursor(0, { item.line_start + 1, 0 })
    end,
    vsplit = function(item)
      if item.kind == "file" then
        vim.cmd("vsplit " .. vim.fn.fnameescape(item.file_path))
        return
      end
      vim.cmd("vsplit " .. vim.fn.fnameescape(item.file_path))
      vim.api.nvim_win_set_cursor(0, { item.line_start + 1, 0 })
    end,
    tab = function(item)
      if item.kind == "file" then
        vim.cmd("tabedit " .. vim.fn.fnameescape(item.file_path))
        return
      end
      vim.cmd("tabedit " .. vim.fn.fnameescape(item.file_path))
      vim.api.nvim_win_set_cursor(0, { item.line_start + 1, 0 })
    end,
    backlinks = function(item)
      require("organ.backlinks").open(item.id)
    end,
  }
end

-- Multi-criteria prefix-token filter.
--
-- Parses a query string and returns:
--   { todo = {...}, priority = {...}, tag = {...}, file = {...}, plain = {...} }
-- "plain" tokens are ANDed against item.title (case-insensitive substring).
-- Prefix tokens: todo:NEXT priority:A tag:work file:inbox
-- Multiple same-prefix tokens are OR'd within that field; different fields AND.
--
-- Exported for testing.
function M.parse_filter_tokens(query_str)
  if not query_str or query_str == "" then
    return { todo = {}, priority = {}, tag = {}, file = {}, plain = {} }
  end
  local result = { todo = {}, priority = {}, tag = {}, file = {}, plain = {} }
  for token in query_str:gmatch("%S+") do
    local prefix, value = token:match("^([a-z]+):(%S+)$")
    if prefix and value then
      if prefix == "todo" then
        result.todo[#result.todo + 1] = value
      elseif prefix == "priority" then
        result.priority[#result.priority + 1] = value
      elseif prefix == "tag" then
        result.tag[#result.tag + 1] = value
      elseif prefix == "file" then
        result.file[#result.file + 1] = value
      else
        -- Unknown prefix: treat whole token as plain text.
        result.plain[#result.plain + 1] = token:lower()
      end
    else
      result.plain[#result.plain + 1] = token:lower()
    end
  end
  return result
end

-- Apply parsed filter tokens to an items array. Returns a new (filtered) array.
-- Items that do not satisfy ALL criteria are dropped.
function M.apply_filter_tokens(items, parsed)
  if not parsed then
    return items
  end
  local has_todo = #parsed.todo > 0
  local has_priority = #parsed.priority > 0
  local has_tag = #parsed.tag > 0
  local has_file = #parsed.file > 0
  local has_plain = #parsed.plain > 0

  if not has_todo and not has_priority and not has_tag and not has_file and not has_plain then
    return items
  end

  local result = {}
  for _, item in ipairs(items) do
    local ok = true

    -- todo: any match in OR list.
    if ok and has_todo then
      local match = false
      for _, v in ipairs(parsed.todo) do
        if (item.todo_state or ""):lower() == v:lower() then
          match = true
          break
        end
      end
      if not match then
        ok = false
      end
    end

    -- priority: any match in OR list.
    if ok and has_priority then
      local match = false
      for _, v in ipairs(parsed.priority) do
        if (item.priority or ""):lower() == v:lower() then
          match = true
          break
        end
      end
      if not match then
        ok = false
      end
    end

    -- tag: any of the OR list must be present.
    if ok and has_tag then
      local match = false
      local item_tags = item.tags or {}
      for _, v in ipairs(parsed.tag) do
        local lv = v:lower()
        for _, t in ipairs(item_tags) do
          if t:lower() == lv then
            match = true
            break
          end
        end
        if match then
          break
        end
      end
      if not match then
        ok = false
      end
    end

    -- file: any substring match in OR list.
    if ok and has_file then
      local match = false
      local fp = (item.file_path or ""):lower()
      for _, v in ipairs(parsed.file) do
        if fp:find(v:lower(), 1, true) then
          match = true
          break
        end
      end
      if not match then
        ok = false
      end
    end

    -- plain: ALL plain tokens must appear in title (AND).
    if ok and has_plain then
      local title_lower = (item.title or ""):lower()
      for _, v in ipairs(parsed.plain) do
        if not title_lower:find(v, 1, true) then
          ok = false
          break
        end
      end
    end

    if ok then
      result[#result + 1] = item
    end
  end
  return result
end

function M.pick(opts)
  opts = opts or {}
  local cfg = require("organ").config.find or {}

  local backend = resolve_backend(opts.backend or cfg.backend or "snacks")
  -- Per-call `opts.columns` takes precedence so callers (e.g. OrgRefile,
  -- which wants `breadcrumb` in place of `path`) can override without
  -- mutating global config.
  local columns = opts.columns
    or cfg.columns
    or { "level", "todo", "priority", "title", "tags", "path" }
  local match_fields = cfg.match_fields or { "title", "tags", "path", "todo", "priority" }
  local items
  if opts.source == "links" then
    local rows = require("organ.query").links(opts.filter or {})
    items = build_link_items(rows, columns, match_fields)
  elseif opts.source == "complete" then
    items = opts.items or {}
  elseif opts.source == "files" then
    local rows = opts.items or require("organ.query").files()
    items = {}
    for _, r in ipairs(rows) do
      local rel = vim.fn.fnamemodify(r.file_path, ":~:.")
      local n = r.headline_count or 0
      local display =
        string.format("%-30s  %d %s  %s", r.basename, n, n == 1 and "headline" or "headlines", rel)
      items[#items + 1] = {
        file_path = r.file_path,
        title = r.basename,
        display = display,
        display_segments = M.format_file_segments(r),
        match = r.basename .. " " .. rel,
        kind = "file",
      }
    end
  else
    -- Request backlink counts when the backlinks column is configured.
    local want_backlinks = false
    for _, col in ipairs(columns) do
      if col == "backlinks" then
        want_backlinks = true
        break
      end
    end
    local filter = opts.filter or {}
    if want_backlinks then
      filter = vim.tbl_extend("keep", filter, { include_backlink_counts = true })
    end
    local rows = opts.items or require("organ.query").headlines(filter)
    items = build_items(rows, columns, match_fields)
  end

  -- Apply prefix-token pre-filtering if caller supplied a query string.
  if opts.query and opts.query ~= "" then
    local parsed = M.parse_filter_tokens(opts.query)
    items = M.apply_filter_tokens(items, parsed)
  end

  local actions = standard_actions()
  if opts.actions then
    for k, v in pairs(opts.actions) do
      actions[k] = v
    end
  end

  backend.pick(items, {
    -- Semantic name shown in each backend's native title slot
    -- (snacks `title`, telescope `prompt_title`, fzf-lua
    -- `winopts.title`).  Plain prose, no trailing colon or arrow --
    -- the backend formats it for its own UI.
    title = opts.title or "Find",
    actions = actions,
    default_action = opts.default_action or "jump",
    keymaps = cfg.keymaps or {},
    create = opts.create,
  })
end

function M.make_insert_link_action(ctx)
  return function(item)
    if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
      require("organ.notify").warn("source buffer no longer valid")
      return
    end
    if ctx.in_link or ctx.in_comment then
      require("organ.notify").warn("refusing to insert link inside link/comment")
      return
    end
    local desc = (ctx.cword and ctx.cword ~= "") and ctx.cword or item.title
    local link = string.format("[[id:%s][%s]]", item.id, desc)

    vim.api.nvim_set_current_buf(ctx.bufnr)
    vim.api.nvim_win_set_cursor(ctx.win, ctx.cursor)
    if ctx.cword and ctx.cword ~= "" then
      -- Find the cword bounds at the cursor and replace via buf_set_text.
      -- Avoids `vim.cmd("normal! ciw" .. link)` where a title containing
      -- a literal newline (rare but possible if the user mis-titled a
      -- node) would split the insert across lines.
      local row = ctx.cursor[1] - 1
      local line = vim.api.nvim_buf_get_lines(ctx.bufnr, row, row + 1, false)[1] or ""
      local col = ctx.cursor[2]
      -- Walk left/right from cursor until non-keyword character.
      local function is_kw(c)
        return c:match("[%w_]") ~= nil
      end
      local lo, hi = col + 1, col + 1
      while lo > 1 and is_kw(line:sub(lo - 1, lo - 1)) do
        lo = lo - 1
      end
      while hi <= #line and is_kw(line:sub(hi, hi)) do
        hi = hi + 1
      end
      vim.api.nvim_buf_set_text(ctx.bufnr, row, lo - 1, row, hi - 1, { link })
    else
      vim.api.nvim_buf_set_text(
        ctx.bufnr,
        ctx.cursor[1] - 1,
        ctx.cursor[2],
        ctx.cursor[1] - 1,
        ctx.cursor[2],
        { link }
      )
    end
  end
end

function M.make_refile_action(ctx)
  return function(item)
    if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
      require("organ.notify").warn("source buffer no longer valid")
      return
    end
    local err =
      require("organ.refile").move(ctx.bufnr, ctx.cursor[1], item.file_path, item.line_start + 1)
    if err then
      require("organ.notify").error("organ: refile failed: " .. err)
    end
  end
end

local function follow_link(item)
  local raw
  local reserved_types = {
    id = true,
    file = true,
    attachment = true,
    headline = true,
    http = true,
    https = true,
    mailto = true,
    text = true,
  }
  if item.target_type == "id" or item.target_type == "file" or item.target_type == "attachment" then
    raw = item.target_type .. ":" .. item.target
  elseif item.target_type == "headline" then
    raw = "*" .. item.target
  elseif not reserved_types[item.target_type] then
    -- Property-value link: reconstruct the original [[KEY:value]] target text.
    raw = item.target_type .. ":" .. item.target
  else
    raw = item.target
  end
  local source = item.source and item.source.file_path or nil
  local action_record = require("organ.link").open(raw, source)
  if action_record.kind == "edit_file" then
    require("organ.link").dispatch_edit_file(action_record)
  elseif action_record.kind == "jump_headline" then
    vim.cmd("edit " .. vim.fn.fnameescape(action_record.file_path))
    vim.api.nvim_win_set_cursor(0, { action_record.line, 0 })
  elseif action_record.kind == "url" then
    if vim.ui.open then
      vim.ui.open(action_record.url)
    else
      require("organ.notify").info("organ: url " .. action_record.url)
    end
  elseif action_record.kind == "headline_search" then
    require("organ.notify").warn("organ: headline search not wired: " .. action_record.title_match)
  elseif action_record.kind == "property_value" then
    require("organ.link").dispatch_property_value(action_record)
  elseif action_record.kind == "error" then
    require("organ.notify").error(action_record.reason)
  end
end

local function jump_to_source(item)
  vim.cmd("edit " .. vim.fn.fnameescape(item.source.file_path))
  vim.api.nvim_win_set_cursor(0, { item.line, 0 })
end

M.actions_links = {
  follow = follow_link,
  jump_to_source = jump_to_source,
}

function M.format_link(r, _columns)
  local source = (r.source_headline and r.source_headline.title) or "(unknown)"
  local target_label
  if r.target_headline then
    target_label = r.target_headline.title
  else
    target_label = string.format("[%s] %s", r.target_type, r.target)
  end
  local desc = (r.description and r.description ~= "") and (' "' .. r.description .. '"') or ""
  local loc =
    string.format("%s:%d", vim.fn.fnamemodify(r.source_headline.file_path, ":~:."), r.line)
  return string.format("%s   ->  %s%s   (%s)", source, target_label, desc, loc)
end

-- Segment form for link rows: same display as format_link, but split
-- into per-element { text, hl } pairs so telescope / fzf-lua / snacks
-- can color source/target titles, descriptions, and source location
-- the same way they color headline rows.
function M.format_link_segments(r)
  local source = (r.source_headline and r.source_headline.title) or "(unknown)"
  local target_label
  if r.target_headline then
    target_label = r.target_headline.title
  else
    target_label = string.format("[%s] %s", r.target_type, r.target)
  end
  local loc =
    string.format("%s:%d", vim.fn.fnamemodify(r.source_headline.file_path, ":~:."), r.line)
  local segs = {}
  -- Per-link icon based on target scheme: id / file / http / etc.
  -- Prefer mini.icons / nvim-web-devicons file icon for `file:`
  -- targets; otherwise fall back to a category-based glyph.
  local icons = require("organ.icons")
  local target_str = r.target or ""
  if r.target_type == "file" or target_str:match("^file:") then
    local path = target_str:gsub("^file:", "")
    local seg = icons.segment(path)
    if seg then
      segs[#segs + 1] = seg
    end
  end
  segs[#segs + 1] = { source, "@organ.find.title" }
  segs[#segs + 1] = { "   ->  ", "@organ.find.path" }
  segs[#segs + 1] = { target_label, "@organ.find.title" }
  if r.description and r.description ~= "" then
    segs[#segs + 1] = { ' "' .. r.description .. '"', "@organ.find.path" }
  end
  segs[#segs + 1] = { "   (" }
  segs[#segs + 1] = { loc, "@organ.find.path" }
  segs[#segs + 1] = { ")" }
  return segs
end

-- Segment form for file rows: basename / headline-count / relative
-- path with semantic colors so files render with the same per-column
-- treatment as headlines and links.  The "headlines" label after the
-- count is intentional -- a bare "(7)" out of context isn't obvious;
-- spelling it out makes the display self-documenting.
function M.format_file_segments(r)
  local rel = vim.fn.fnamemodify(r.file_path, ":~:.")
  local n = r.headline_count or 0
  local label = n == 1 and "headline" or "headlines"
  local segs = {}
  local icon = require("organ.icons").segment(r.file_path)
  if icon then
    segs[#segs + 1] = icon
  end
  segs[#segs + 1] = { string.format("%-30s", r.basename), "@org.heading.1" }
  segs[#segs + 1] = { "  " }
  segs[#segs + 1] = { tostring(n), "@organ.find.backlinks" }
  segs[#segs + 1] = { " " .. label .. "  " }
  segs[#segs + 1] = { rel, "@organ.find.path" }
  return segs
end

-- Property-key completer for `:Org find ref` -- offers every distinct
-- key found in the indexed `properties` table.
local function complete_property_keys(arg_lead)
  local h = require("organ.runtime").db()
  if not h then
    return {}
  end
  local out, db_mod = {}, require("organ.db")
  local stmt = h:prepare("SELECT DISTINCT key FROM properties ORDER BY key")
  if stmt then
    while stmt:step() == db_mod.SQLITE_ROW do
      local k = stmt:column_text(0)
      if k:find(arg_lead, 1, true) == 1 then
        out[#out + 1] = k
      end
    end
    stmt:finalize()
  end
  return out
end

-- Target-type completer for `:Org find link`.  Includes whatever
-- target types the index has seen plus a fixed core set so first-time
-- completion is useful before any link has been indexed.
local function complete_link_target_types(arg_lead)
  local seen = {}
  local h = require("organ.runtime").db()
  local db_mod = require("organ.db")
  if h then
    local stmt = h:prepare("SELECT DISTINCT target_type FROM links")
    if stmt then
      while stmt:step() == db_mod.SQLITE_ROW do
        seen[stmt:column_text(0)] = true
      end
      stmt:finalize()
    end
  end
  for _, t in ipairs({ "id", "file", "http", "https", "mailto", "attachment", "headline", "text" }) do
    seen[t] = true
  end
  local out = {}
  for t in pairs(seen) do
    if t:find(arg_lead, 1, true) == 1 then
      out[#out + 1] = t
    end
  end
  table.sort(out)
  return out
end

M.commands = {
  find = {
    fn = function()
      M.pick({
        source = "headlines",
        filter = {},
        title = "Find headline",
        default_action = "jump",
      })
    end,
    desc = "Find any headline",
  },
  ["find file"] = {
    fn = function()
      M.pick({ source = "files", title = "Find file", default_action = "jump" })
    end,
    desc = "Find an org file by name",
  },
  ["find tag"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      local filter = args ~= "" and { tags = { all = vim.split(args, ",") } } or {}
      M.pick({
        source = "headlines",
        filter = filter,
        title = "Find by tag",
        default_action = "jump",
      })
    end,
    nargs = "?",
    desc = "Find headlines by tag (comma-separated)",
  },
  ["find todo"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      local todo = (args ~= "") and vim.split(args, ",") or { "TODO", "NEXT" }
      M.pick({
        source = "headlines",
        filter = { todo = { include = todo } },
        title = "Find TODO",
        default_action = "jump",
      })
    end,
    nargs = "?",
    desc = "Find headlines by TODO state (comma-separated)",
  },
  ["find link"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      local filter = {}
      if args ~= "" then
        filter.target_type = args
      end
      M.pick({
        source = "links",
        filter = filter,
        title = "Find link",
        default_action = "follow",
        actions = {
          follow = M.actions_links.follow,
          jump_to_source = M.actions_links.jump_to_source,
        },
      })
    end,
    nargs = "?",
    complete = complete_link_target_types,
    desc = "Find an org link in the index (optional comma-separated target types)",
  },
  ["find ref"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      local key = (args ~= "") and args or "ROAM_REFS"
      M.pick({
        source = "headlines",
        filter = { has_property = key },
        default_action = "jump",
        title = "Find by " .. key,
      })
    end,
    nargs = "?",
    complete = complete_property_keys,
    desc = "Find a headline by property key (default: ROAM_REFS)",
  },
}

return M
