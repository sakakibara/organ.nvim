-- lua/organ/archive.lua
-- Implements :Org archive subtree — moves the subtree at (or containing) `line`
-- into the archive file, matching Emacs's org-archive-subtree (C-c $).

local M = {}

-- Helpers

local structure = require("organ.structure")

-- Parse the headline text to extract the TODO keyword and bare title.
-- Returns (todo_keyword_or_nil, bare_title).
-- headline.title_text may look like "TODO Fix the thing :tag:" — we just want
-- the first word if it's a known keyword.
local function split_todo(title_text, todo_sequence)
  if not title_text or title_text == "" then
    return nil, title_text
  end
  local first_word, rest = title_text:match("^(%S+)%s*(.-)%s*$")
  if not first_word then
    return nil, title_text
  end
  if not todo_sequence then
    return nil, title_text
  end
  for _, kw in ipairs(todo_sequence) do
    if kw ~= "|" and kw == first_word then
      return kw, rest
    end
  end
  return nil, title_text
end

-- Compute parent-chain path like "GrandParent/Parent".
-- Returns a string or "" if the headline has no parents.
local function parent_chain(bufnr, headline)
  local parts = {}
  local level = headline.level
  -- Walk backwards from hl.line - 1 collecting first headline at each
  -- decreasing level.
  local target_level = level - 1
  local scan_from = headline.line - 1
  while target_level >= 1 and scan_from >= 1 do
    for i = scan_from, 1, -1 do
      local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
      local stars, title = txt:match("^(%*+)%s+(.-)%s*$")
      if stars and #stars == target_level then
        table.insert(parts, 1, title)
        scan_from = i - 1
        target_level = target_level - 1
        break
      elseif stars and #stars < target_level then
        -- Jumped above without finding the level: stop
        scan_from = 0
        break
      end
    end
    if scan_from == 0 then
      break
    end
  end
  return table.concat(parts, "/")
end

-- Ensure the file exists, creating parent dirs as needed.
local function ensure_file(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  if not vim.loop.fs_stat(path) then
    vim.fn.writefile({}, path)
  end
end

-- Read file lines (returns {} if missing).
local function read_file_lines(path)
  if not vim.loop.fs_stat(path) then
    return {}
  end
  return vim.fn.readfile(path)
end

-- Find (1-based) the line of the given top-level headline title in lines.
-- Returns nil if not found.
local function find_top_headline(lines, title)
  for i, l in ipairs(lines) do
    local stars, t = l:match("^(%*+)%s+(.-)%s*$")
    if stars and #stars == 1 and t == title then
      return i
    end
  end
  return nil
end

-- Re-level a list of lines so the top headline goes from src_level to
-- dst_level (all nested headlines shift by the same delta).
local function relevel_lines(lines, src_level, dst_level)
  local delta = dst_level - src_level
  if delta == 0 then
    return lines
  end
  local out = {}
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+)")
    if stars then
      local new_level = math.max(1, #stars + delta)
      out[#out + 1] = string.rep("*", new_level) .. l:sub(#stars + 1)
    else
      out[#out + 1] = l
    end
  end
  return out
end

-- Insert a :PROPERTIES: drawer (or append to existing one) with the given
-- key/value pairs into `lines` right after line 1 (the headline line).
-- `pairs_list` is a list of { key, value } tables (ordered).
-- Returns the modified lines table.
local function inject_properties(lines, pairs_list)
  if #pairs_list == 0 then
    return lines
  end

  -- Find whether there's an existing :PROPERTIES: drawer already.
  -- It must start right after the headline (line index 2 = lines[2]).
  local insert_before_end = nil -- 1-based index of :END: line
  local drawer_start = nil

  -- Skip planning lines (SCHEDULED/DEADLINE/CLOSED) before looking for drawer.
  local scan = 2
  while scan <= #lines do
    local l = lines[scan]
    if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
      scan = scan + 1
    else
      break
    end
  end

  if scan <= #lines and lines[scan]:match("^%s*:PROPERTIES:%s*$") then
    drawer_start = scan
    for i = scan + 1, #lines do
      if lines[i]:match("^%s*:END:%s*$") then
        insert_before_end = i
        break
      end
    end
  end

  local prop_lines = {}
  for _, kv in ipairs(pairs_list) do
    prop_lines[#prop_lines + 1] = ":" .. kv[1] .. ": " .. kv[2]
  end

  if insert_before_end then
    -- Inject before :END: (insert_before_end - 1 is the last prop line idx)
    local out = {}
    for i = 1, insert_before_end - 1 do
      out[#out + 1] = lines[i]
    end
    for _, pl in ipairs(prop_lines) do
      out[#out + 1] = pl
    end
    for i = insert_before_end, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  else
    -- No existing drawer: insert after line 1 (the headline).
    local out = { lines[1] }
    out[#out + 1] = ":PROPERTIES:"
    for _, pl in ipairs(prop_lines) do
      out[#out + 1] = pl
    end
    out[#out + 1] = ":END:"
    for i = 2, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  end
end

-- Public API

--- Archive the subtree containing `line` in `bufnr` to the configured archive
--- file.  Both `bufnr` and `line` default to the current buffer + cursor.
--- @param opts? { bufnr?: number, line?: number }
--- @return string|nil err  nil on success, error string on failure.
--- @return string|nil archive_path  Absolute path written to (on success).
function M.archive_subtree(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")

  local cfg = (require("organ").config.archive or {})
  if cfg.enabled == false then
    return "archive feature is disabled"
  end

  -- 1. Find containing headline.
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end

  -- 2. Compute subtree end.
  local subtree_end = structure._subtree_end(bufnr, hl)

  -- 3. Source file path.
  local src_path = vim.api.nvim_buf_get_name(bufnr)
  if src_path == "" then
    return "buffer has no file path"
  end
  src_path = vim.fn.fnamemodify(src_path, ":p") -- expand to absolute

  -- 4. Determine archive file path.
  local archive_path
  local file_pattern = cfg.file_pattern or "%s_archive"
  if type(file_pattern) == "function" then
    archive_path = file_pattern(src_path)
  else
    archive_path = string.format(file_pattern, src_path)
  end
  archive_path = vim.fn.fnamemodify(archive_path, ":p")

  -- 5. Determine archive headline title.
  local archive_hl_title = cfg.headline or "Archive"

  -- 6. Read subtree lines from source buffer.
  local subtree_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  if #subtree_lines == 0 then
    return "subtree is empty"
  end

  -- 7. Collect metadata.
  local now_ts = os.time()
  local archive_time = os.date("[%Y-%m-%d %a %H:%M]", now_ts)

  local olpath = parent_chain(bufnr, hl)

  -- Extract TODO keyword from headline title for ARCHIVE_TODO.
  local todo_seq = require("organ.todo").all_keywords()
  local todo_kw, bare_title = split_todo(hl.title_text, todo_seq)

  -- 8. Open (or create) the archive file.
  ensure_file(archive_path)
  local arc_lines = read_file_lines(archive_path)

  -- Find or create the archive headline.
  local arc_hl_line = find_top_headline(arc_lines, archive_hl_title)
  if not arc_hl_line then
    -- Append "* <headline>" to archive file.
    arc_lines[#arc_lines + 1] = "* " .. archive_hl_title
    arc_hl_line = #arc_lines
  end

  -- Archive headline level is 1 (top-level "* Archive").
  -- Moved subtree top should become level 2 (child of archive hl).
  local dst_level = 2 -- child of level-1 archive headline
  local releveled = relevel_lines(subtree_lines, hl.level, dst_level)

  -- 9. Inject metadata into the moved subtree's top headline (releveled[1]).
  -- `add_metadata = true/false` is a coarse on/off; `save_context_info`
  -- (Emacs `org-archive-save-context-info`, default
  -- `{"time","file","olpath","category","todo","itags"}`) chooses
  -- WHICH context properties to inject.  Defaults match Emacs.
  local add_meta = cfg.add_metadata
  if add_meta == nil then
    add_meta = true
  end
  local context_set
  if cfg.save_context_info ~= nil then
    context_set = {}
    for _, k in ipairs(cfg.save_context_info) do
      context_set[k] = true
    end
  else
    context_set = {
      time = true,
      file = true,
      olpath = true,
      category = true,
      todo = true,
      itags = true,
    }
  end

  if add_meta then
    local props = {}
    if context_set.time then
      props[#props + 1] = { "ARCHIVE_TIME", archive_time }
    end
    if context_set.file then
      props[#props + 1] = { "ARCHIVE_FILE", src_path }
    end
    if context_set.olpath and olpath ~= "" then
      props[#props + 1] = { "ARCHIVE_OLPATH", olpath }
    end
    if context_set.todo and todo_kw then
      props[#props + 1] = { "ARCHIVE_TODO", todo_kw }
    end
    if context_set.category then
      local cat = require("organ.agenda")
      -- File category resolution is private to agenda; do a cheap
      -- file-basename fallback so we always emit ARCHIVE_CATEGORY
      -- when `category` is in the set.
      local base = src_path:match("([^/]+)%.org$") or src_path:match("([^/]+)$") or ""
      local _ = cat
      if base ~= "" then
        props[#props + 1] = { "ARCHIVE_CATEGORY", base }
      end
    end
    if context_set.itags then
      -- Inherited tags would require a query lookup; skip when absent.
      if hl and hl.tags and #hl.tags > 0 then
        props[#props + 1] = { "ARCHIVE_ITAGS", table.concat(hl.tags, " ") }
      end
    end
    releveled = inject_properties(releveled, props)
  end

  -- If there was a TODO keyword, strip it from the moved headline's first line
  -- so it doesn't pollute archive agenda.
  if todo_kw and add_meta then
    local first = releveled[1]
    -- Replace "* TODO <rest>" with "* <bare_title>" (bare_title already stripped)
    local stars_part = first:match("^(%*+%s+)")
    if stars_part then
      releveled[1] = stars_part .. bare_title
    end
  end

  -- 10. Insert the releveled subtree right after the archive headline (append
  --     to its section, i.e. at the end of the file if Archive is the last hl).
  -- Find the end of the archive headline's section (where to insert).
  -- We walk forward from arc_hl_line+1 looking for a sibling or parent headline.
  local insert_at = #arc_lines + 1 -- default: append at end
  do
    local arc_lvl = 1 -- "* Archive" is level 1
    for i = arc_hl_line + 1, #arc_lines do
      local l = arc_lines[i]
      local stars = l:match("^(%*+)%s")
      if stars and #stars <= arc_lvl then
        insert_at = i
        break
      end
    end
  end

  -- Build new archive file content.
  local new_arc = {}
  for i = 1, insert_at - 1 do
    new_arc[#new_arc + 1] = arc_lines[i]
  end
  for _, l in ipairs(releveled) do
    new_arc[#new_arc + 1] = l
  end
  for i = insert_at, #arc_lines do
    new_arc[#new_arc + 1] = arc_lines[i]
  end

  -- 11. Write archive file (atomic — a crash mid-write would otherwise
  -- corrupt the user's archive).
  local ok, err =
    require("organ.path").write_atomic(archive_path, table.concat(new_arc, "\n") .. "\n")
  if not ok then
    return "failed to write archive file: " .. tostring(err)
  end

  -- 12. Delete original subtree from source buffer.
  vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, subtree_end, false, {})

  -- 12a. Tidy the deletion site so leftover blank-line stragglers
  -- collapse to whatever pattern the surviving buffer uses.
  pcall(function()
    require("organ.spacing").normalize_at_cut(bufnr, hl.line)
  end)

  -- 13. Save source buffer.
  local cur = vim.api.nvim_get_current_buf()
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(bufnr)
  end
  vim.cmd("silent! write")
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(cur)
  end

  return nil, archive_path
end

-- Archive to a sibling `* Archive` headline within the SAME buffer (Emacs
-- C-c C-x A). Reuses the metadata-injection + relevel helpers above.
--- Archive the subtree at cursor under a sibling `* Archive` headline in the
--- SAME buffer (Emacs `C-c C-x A`).  Both `bufnr` and `line` default to the
--- current buffer + cursor.
--- @param opts? { bufnr?: number, line?: number }
--- @return string|nil err  nil on success, error string on failure.
function M.archive_to_sibling(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local cfg = (require("organ").config.archive or {})
  if cfg.enabled == false then
    return "archive feature is disabled"
  end

  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local subtree_end = structure._subtree_end(bufnr, hl)
  local subtree_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  if #subtree_lines == 0 then
    return "subtree is empty"
  end

  local archive_hl_title = cfg.headline or "Archive"
  local now_ts = os.time()
  local archive_time = os.date("[%Y-%m-%d %a %H:%M]", now_ts)

  local olpath = parent_chain(bufnr, hl)
  local todo_seq = require("organ.todo").all_keywords()
  local todo_kw, bare_title = split_todo(hl.title_text, todo_seq)

  -- Read entire buffer to operate in memory.
  local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Locate or create the top-level Archive headline.
  local arc_hl_line = find_top_headline(all, archive_hl_title)
  local appended = false
  if not arc_hl_line then
    -- Append at end with a leading blank-line separator.
    if all[#all] and all[#all] ~= "" then
      all[#all + 1] = ""
    end
    all[#all + 1] = "* " .. archive_hl_title
    arc_hl_line = #all
    appended = true
  end

  -- Re-level the subtree: top becomes level 2 under "* Archive".
  local releveled = relevel_lines(subtree_lines, hl.level, 2)

  local add_meta = cfg.add_metadata
  if add_meta == nil then
    add_meta = true
  end
  if add_meta then
    local props = {
      { "ARCHIVE_TIME", archive_time },
      { "ARCHIVE_OLPATH", olpath ~= "" and olpath or nil },
      { "ARCHIVE_TODO", todo_kw },
    }
    -- Drop nil-valued slots before inject_properties.
    local filtered = {}
    for _, p in ipairs(props) do
      if p[2] then
        filtered[#filtered + 1] = p
      end
    end
    releveled = inject_properties(releveled, filtered)
  end

  if todo_kw and add_meta then
    local stars_part = releveled[1]:match("^(%*+%s+)")
    if stars_part then
      releveled[1] = stars_part .. bare_title
    end
  end

  -- Insertion point: end of the Archive headline's section.
  local insert_at = #all + 1
  for i = arc_hl_line + 1, #all do
    local stars = (all[i] or ""):match("^(%*+)%s")
    if stars and #stars <= 1 then
      insert_at = i
      break
    end
  end

  -- Compute updated buffer: subtree removed from source, appended into Archive.
  local out = {}
  -- The Archive headline may sit before or after the source subtree; build
  -- the new buffer content respecting both cases.
  local function append_archive_block(buf)
    -- Archive block already in `all` past hl.line..subtree_end is preserved
    -- because we walk `all` once below. This helper just emits the moved
    -- subtree lines at the right spot.
    for _, l in ipairs(releveled) do
      buf[#buf + 1] = l
    end
  end

  for i, ln in ipairs(all) do
    -- Skip the source subtree.
    if i >= hl.line and i <= subtree_end then
      -- nothing
    else
      out[#out + 1] = ln
      -- After the Archive headline's section ends, splice in the moved subtree.
      if i + 1 == insert_at then
        -- We're right before the line that would terminate the archive section
        -- (a sibling/parent headline). Insert here.
        if i >= arc_hl_line then -- only after we've already passed Archive
          append_archive_block(out)
        end
      end
    end
  end
  -- If insert_at points past EOF (Archive is last and no terminating headline),
  -- the loop above never inserted; do it now.
  local appended_in_loop = false
  do
    -- Detect via reverse search: is the moved subtree's first line in `out`?
    for j = #out, 1, -1 do
      if out[j] == releveled[1] then
        appended_in_loop = true
        break
      end
    end
  end
  if not appended_in_loop then
    append_archive_block(out)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out)

  -- Tidy the cut site so leftover blank-line stragglers collapse to
  -- whatever pattern the surviving buffer uses.
  pcall(function()
    require("organ.spacing").normalize_at_cut(bufnr, hl.line)
  end)

  -- Save source buffer.
  local cur = vim.api.nvim_get_current_buf()
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(bufnr)
  end
  vim.cmd("silent! write")
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(cur)
  end

  return nil
end

local function notify_archived(arc_path)
  if require("organ").config.notify then
    vim.schedule(function()
      require("organ.notify").info("archived to " .. (arc_path or "archive file"))
    end)
  end
end

-- Set the `:ARCHIVE:` tag on the headline at cursor without moving
-- it.  Emacs `org-archive-set-tag` / `org-toggle-archive-tag`
-- equivalent.  When the tag is already set, this is a no-op.
function M.set_archive_tag(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local tag_writer = require("organ.tag_writer")
  local current = (tag_writer.read(bufnr, hl.line) or {}).tags or {}
  for _, t in ipairs(current) do
    if t == "ARCHIVE" then
      return nil -- already tagged; no-op
    end
  end
  current[#current + 1] = "ARCHIVE"
  return tag_writer.write(bufnr, hl.line, current)
end

-- Dispatch to the action chosen by `archive.default_command`.
function M.default(opts)
  local cmd = (require("organ").config.archive or {}).default_command or "subtree"
  if cmd == "to_archive_sibling" then
    return M.archive_to_sibling(opts)
  end
  if cmd == "set_archive_tag" then
    return M.set_archive_tag(opts)
  end
  return M.archive_subtree(opts)
end

M.commands = {
  archive = {
    fn = function()
      local err, arc_path = M.default()
      if err then
        require("organ.notify").error(err)
      elseif arc_path then
        notify_archived(arc_path)
      else
        require("organ.notify").info("archived")
      end
    end,
    desc = "Archive the subtree using `archive.default_command` (Emacs C-c $)",
  },
  ["archive subtree"] = {
    fn = function()
      local err, arc_path = M.archive_subtree()
      if err then
        require("organ.notify").error(err)
      else
        notify_archived(arc_path)
      end
    end,
    desc = "Archive the subtree at cursor to the archive file",
  },
  ["archive to_sibling"] = {
    fn = function()
      local err = M.archive_to_sibling()
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("subtree archived to sibling")
      end
    end,
    desc = "Archive the subtree to a sibling under an Archive heading in the same file",
  },
  ["archive set_tag"] = {
    fn = function()
      local err = M.set_archive_tag()
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("archive tag set")
      end
    end,
    desc = "Toggle the :ARCHIVE: tag on the headline at cursor (no move)",
  },
}

return M
