-- Subtree-move helper for organ.nvim. Used by find's refile_here action.

local M = {}

-- High-level action: refile the subtree at (`opts.bufnr`, `opts.line`) under
-- a target headline picked via the find UI.  Both keys default to current
-- buffer + cursor.  Honors `config.refile.use_outline_path` (column choice)
-- and `config.refile.targets` (candidate filter), mirroring Emacs's
-- `org-refile-use-outline-path` / `org-refile-targets`.
function M.refile(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")

  local find = require("organ.find")
  local rcfg = (require("organ").config.refile or {})

  -- Column choice (mirror Emacs `org-refile-use-outline-path`):
  --   "outline"      → breadcrumb (file → parent chain → heading)
  --   "file"         → bare file path + heading
  --   "full"         → full canonical path + breadcrumb
  --   "buffer-name"  → buffer's basename
  --   nil / unset    → outline (default; matches Emacs t-form)
  local outline = rcfg.use_outline_path
  if outline == nil then
    outline = "outline"
  end
  local cols
  if outline == "file" then
    cols = { "level", "todo", "priority", "title", "tags", "path" }
  elseif outline == "full" then
    cols = { "level", "todo", "priority", "title", "tags", "breadcrumb", "path" }
  else
    cols = { "level", "todo", "priority", "title", "tags", "breadcrumb" }
  end
  local cfg_cols = (require("organ").config.find or {}).columns
  if cfg_cols and cfg_cols ~= require("organ.defaults").find.columns then
    cols = cfg_cols
  end

  -- Build filter from `refile.targets` (mirror Emacs `org-refile-
  -- targets`).  Each rule narrows the candidate pool to a subset of
  -- indexed headlines.  Multiple rules → union of matches.
  --
  -- Rule shape:
  --   { files = ..., max_level = N, regex = "..." }
  --
  -- `files` recognised forms:
  --   "agenda_files"  use `config.agenda_files` (default behavior of
  --                   Emacs's `org-agenda-files`)
  --   "current"       only the current buffer's file
  --   <list>          explicit list of paths / globs (forwarded to the
  --                   same resolver used by `block.files`)
  --   <function>      called with no args, returns a list
  --   <glob string>   single glob (e.g. "**/*.org", "!**/archive/**")
  local filter = {}
  if type(rcfg.targets) == "table" and #rcfg.targets > 0 then
    local agenda = require("organ.agenda")
    local file_set, has_max = {}, nil
    local function add_files(spec)
      if spec == "current" then
        local p = vim.api.nvim_buf_get_name(bufnr)
        if p ~= "" then
          file_set[p] = true
        end
      elseif spec == "agenda_files" then
        local af = (require("organ").config or {}).agenda_files
        if af then
          for _, p in ipairs(agenda.resolve_agenda_files(af) or {}) do
            file_set[p] = true
          end
        end
      elseif type(spec) == "function" then
        local ok, lst = pcall(spec)
        if ok and type(lst) == "table" then
          for _, p in ipairs(lst) do
            file_set[p] = true
          end
        end
      elseif spec ~= nil then
        for _, p in ipairs(agenda.resolve_agenda_files(spec) or {}) do
          file_set[p] = true
        end
      end
    end
    for _, rule in ipairs(rcfg.targets) do
      add_files(rule.files)
      if rule.max_level then
        if not has_max or rule.max_level > has_max then
          has_max = rule.max_level
        end
      end
    end
    local files = {}
    for p in pairs(file_set) do
      files[#files + 1] = p
    end
    if #files > 0 then
      filter.files = files
    end
    if has_max then
      filter.level = { max = has_max }
    end
  end

  find.pick({
    source = "headlines",
    filter = filter,
    columns = cols,
    title = "Refile to",
    default_action = "refile_here",
    actions = { refile_here = find.make_refile_action({ bufnr = bufnr, cursor = { line, 0 } }) },
  })
end

function M.move(src_bufnr, src_line, target_file, target_line)
  if not vim.api.nvim_buf_is_valid(src_bufnr) then
    return "source buffer no longer valid"
  end

  local lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)

  -- Walk up to the headline that owns src_line (1-based).
  local hl_line = src_line
  while hl_line >= 1 and not lines[hl_line]:match("^%*+%s") do
    hl_line = hl_line - 1
  end
  if hl_line < 1 then
    return "no headline at or above cursor"
  end

  local stars = lines[hl_line]:match("^(%*+)")
  local src_level = #stars

  -- Subtree end: next line at level <= src_level, else EOF.
  local end_line = #lines + 1
  for i = hl_line + 1, #lines do
    local hl = lines[i]:match("^(%*+)%s")
    if hl and #hl <= src_level then
      end_line = i
      break
    end
  end
  local subtree = vim.list_slice(lines, hl_line, end_line - 1)

  -- Load target buffer, validate target headline.  Resolve to a
  -- canonical path first + scan loaded buffers so a window already
  -- displaying the target (possibly opened via symlink / relative
  -- path) is reused -- otherwise bufadd would create a SECOND
  -- buffer and the user's existing window wouldn't reflect the move.
  local pathmod = require("organ.path")
  local canonical = pathmod.canonical(target_file) or target_file
  local target_bufnr
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      local bcanon = pathmod.canonical(name) or name
      if bcanon == canonical then
        target_bufnr = b
        break
      end
    end
  end
  if not target_bufnr then
    target_bufnr = vim.fn.bufadd(canonical)
    vim.fn.bufload(target_bufnr)
  end
  local tlines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
  local target_stars = tlines[target_line] and tlines[target_line]:match("^(%*+)")
  if not target_stars then
    return "target line is not a headline"
  end
  local target_level = #target_stars

  -- Re-indent: top headline becomes target_level + 1; nested shift by delta.
  local delta = (target_level + 1) - src_level
  for i, ln in ipairs(subtree) do
    local s = ln:match("^(%*+)")
    if s then
      subtree[i] = string.rep("*", #s + delta) .. ln:sub(#s + 1)
    end
  end

  -- Apply mutations. Same-buffer case adjusts the insertion offset.
  if target_bufnr == src_bufnr then
    if target_line >= end_line then
      local removed = end_line - hl_line
      vim.api.nvim_buf_set_lines(src_bufnr, hl_line - 1, end_line - 1, false, {})
      vim.api.nvim_buf_set_lines(
        src_bufnr,
        target_line - removed,
        target_line - removed,
        false,
        subtree
      )
    else
      vim.api.nvim_buf_set_lines(src_bufnr, hl_line - 1, end_line - 1, false, {})
      vim.api.nvim_buf_set_lines(src_bufnr, target_line, target_line, false, subtree)
    end
  else
    vim.api.nvim_buf_set_lines(src_bufnr, hl_line - 1, end_line - 1, false, {})
    vim.api.nvim_buf_set_lines(target_bufnr, target_line, target_line, false, subtree)
  end

  -- LOGBOOK refile note. Recorded BEFORE the save so the entry persists.
  local cfg = (require("organ").config.todo or {})
  local policy = cfg.log_refile
  if policy == "time" or policy == "note" then
    -- The moved subtree's new headline is at:
    --   same buffer + target_line + 1, when target_line >= end_line was the
    --     case (subtree was removed first); offset is target_line - removed.
    --   same buffer + target_line + 1 otherwise.
    --   different buffer + target_line + 1.
    local new_hl
    if target_bufnr == src_bufnr then
      if target_line >= end_line then
        new_hl = (target_line - (end_line - hl_line)) + 1
      else
        new_hl = target_line + 1
      end
    else
      new_hl = target_line + 1
    end
    require("organ.logbook").write_planning_change(target_bufnr, new_hl, policy, "Refiled", nil)
  end

  -- Tidy spacing at the cut site (source) and around the new
  -- destination headline (target).  Cross-buffer refile may move from
  -- one spacing convention to another; normalize both ends so the
  -- result reads consistently in each buffer.
  pcall(function()
    local spacing = require("organ.spacing")
    spacing.normalize_at_cut(src_bufnr, hl_line)
    local dest_hl
    if target_bufnr == src_bufnr then
      if target_line >= end_line then
        dest_hl = (target_line - (end_line - hl_line)) + 1
      else
        dest_hl = target_line + 1
      end
    else
      dest_hl = target_line + 1
    end
    spacing.normalize_around(target_bufnr, dest_hl)
  end)

  -- Save both. BufWritePost autocmds re-index.
  local cur = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(src_bufnr)
  vim.cmd("silent! write")
  if target_bufnr ~= src_bufnr then
    vim.api.nvim_set_current_buf(target_bufnr)
    vim.cmd("silent! write")
  end
  vim.api.nvim_set_current_buf(cur)

  return nil
end

M.commands = {
  refile = {
    fn = function()
      M.refile()
    end,
    desc = "Refile current subtree under chosen headline",
  },
}

return M
