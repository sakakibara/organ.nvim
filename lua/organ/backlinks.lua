-- Backlinks buffer for organ.nvim.
--
-- M.open(headline_id) -> bufnr
--   Creates a nofile buffer listing all incoming links to the given headline.
--
-- M.refresh(bufnr) — re-run the query + re-render.
-- Subscribes to the "indexed" event (debounced) to auto-refresh on DB changes.

local M = {}

local obuf = require("organ.buf")
local NS = vim.api.nvim_create_namespace("organ-backlinks")

local function buf_state(bufnr)
  return vim.b[bufnr].organ_backlinks or {}
end
local function set_state(bufnr, s)
  vim.b[bufnr].organ_backlinks = s
end

local function apply_extmarks(bufnr, extmarks)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, mk in ipairs(extmarks) do
    local lnum, hl, col_start, col_end = mk[1], mk[2], mk[3], mk[4]
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum - 1, col_start, {
      end_col = col_end,
      hl_group = hl,
    })
  end
end

-- Two-line entry layout:
--   • TODO [#A] Source headline title
--     basename.org · L42  "optional description"
-- Bullet + indent communicates "nested item" naturally; basename
-- (not full path) keeps the location line readable in narrow
-- sidebars; "·" reads cleaner than ":" or "/".  Extmarks position
-- highlights per-segment as before.
local function format_entry(r)
  local out = {} -- list of { line, marks = { { hl, col_start, col_end }, ... } }

  -- Line 1: bullet + optional TODO + optional priority + title.
  local parts1, marks1 = {}, {}
  local col = 0
  local function append(s, hl)
    if hl then
      marks1[#marks1 + 1] = { hl, col, col + #s }
    end
    parts1[#parts1 + 1] = s
    col = col + #s
  end
  append("• ", nil)
  if r.source_headline.todo_state then
    local kw = r.source_headline.todo_state
    append(kw, "@organ.backlinks.todo_" .. kw:lower())
    append(" ", nil)
  end
  if r.source_headline.priority then
    local prio = r.source_headline.priority
    append("[#" .. prio .. "]", "@organ.backlinks.priority_" .. prio)
    append(" ", nil)
  end
  local title = r.source_headline.title or "(no title)"
  append(title, "@organ.backlinks.source_title")
  out[1] = { line = table.concat(parts1), marks = marks1 }

  -- Line 2: indented location + description.  Indent matches the
  -- bullet's title column so it reads as a continuation of line 1.
  local parts2, marks2 = {}, {}
  col = 0
  local function append2(s, hl)
    if hl then
      marks2[#marks2 + 1] = { hl, col, col + #s }
    end
    parts2[#parts2 + 1] = s
    col = col + #s
  end
  append2("  ", nil) -- continuation indent: 2 chars (under "• ")
  local basename = vim.fn.fnamemodify(r.source_headline.file_path or "?", ":t")
  local loc = basename .. " · L" .. tostring(r.line or 1)
  append2(loc, "@organ.backlinks.location")
  if r.description and r.description ~= "" then
    append2("  ", nil)
    append2('"' .. r.description .. '"', "@organ.backlinks.description")
  end
  out[2] = { line = table.concat(parts2), marks = marks2 }

  return out
end

function M.render(target_headline, rows)
  local lines, extmarks, line_index = {}, {}, {}
  local function emit(text, marks, row)
    lines[#lines + 1] = text
    local lnum = #lines
    if marks then
      for _, mk in ipairs(marks) do
        extmarks[#extmarks + 1] = { lnum, mk[1], mk[2], mk[3] }
      end
    end
    line_index[lnum] = row
  end

  -- Header: "<count> Backlink(s) → <title>" + a separator rule.
  -- Title row is highlighted as a unit so colorschemes can theme it.
  local count = #rows
  local plural = count == 1 and "" or "s"
  local title = target_headline.title or "(unknown)"
  local header = string.format("%d Backlink%s  →  %s", count, plural, title)
  emit(header, { { "@organ.backlinks.header", 0, #header } }, nil)
  -- Soft horizontal rule under the header.  Uses the "─" U+2500
  -- box-drawing char which renders cleanly in any monospace font.
  local rule = string.rep("─", math.max(8, #header))
  emit(rule, { { "@organ.backlinks.rule", 0, #rule } }, nil)
  emit("", nil, nil)

  if #rows == 0 then
    emit("(no incoming links yet)", nil, nil)
  else
    for i, r in ipairs(rows) do
      local entry = format_entry(r)
      emit(entry[1].line, entry[1].marks, r)
      emit(entry[2].line, entry[2].marks, r)
      if i < #rows then
        emit("", nil, nil)
      end
    end
  end
  return { lines = lines, extmarks = extmarks, line_index = line_index }
end

local hl_registered = false
local function register_highlights()
  if hl_registered then
    return
  end
  hl_registered = true
  local hls = {
    ["@organ.backlinks.header"] = "Title",
    ["@organ.backlinks.rule"] = "Comment",
    ["@organ.backlinks.source_title"] = "Normal",
    ["@organ.backlinks.todo_todo"] = "WarningMsg",
    ["@organ.backlinks.todo_next"] = "Statement",
    ["@organ.backlinks.todo_done"] = "Comment",
    ["@organ.backlinks.priority_A"] = "ErrorMsg",
    ["@organ.backlinks.priority_B"] = "WarningMsg",
    ["@organ.backlinks.priority_C"] = "Comment",
    ["@organ.backlinks.location"] = "Directory",
    ["@organ.backlinks.description"] = "String",
  }
  for group, link in pairs(hls) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local state = buf_state(bufnr)
  local id = state.id
  if not id then
    return
  end
  local query = require("organ.query")
  local target = query.get_by_id(id)
  if not target then
    vim.bo[bufnr].modifiable = true
    obuf.set_lines(bufnr, 0, -1, { "Backlinks: id not indexed — " .. id })
    vim.bo[bufnr].modifiable = false
    return
  end
  local rows = query.links_to(id)
  -- Also include `[[*Title]]` references — they're real backlinks even
  -- though they don't carry the ID. Union by source_headline_id+line
  -- so a single source row referencing both id: AND *Title once isn't
  -- counted twice.
  if target.title and target.title ~= "" then
    local seen = {}
    for _, r in ipairs(rows) do
      local k = (r.source_headline.id or "?") .. ":" .. (r.line or 0)
      seen[k] = true
    end
    for _, r in ipairs(query.title_refs(target.title) or {}) do
      local k = (r.source_headline.id or "?") .. ":" .. (r.line or 0)
      if not seen[k] then
        rows[#rows + 1] = r
        seen[k] = true
      end
    end
  end
  local out = M.render(target, rows)

  vim.bo[bufnr].modifiable = true
  obuf.set_lines(bufnr, 0, -1, out.lines)
  vim.bo[bufnr].modifiable = false
  apply_extmarks(bufnr, out.extmarks)

  state.target = {
    id = target.id,
    title = target.title,
    file_path = target.file_path,
    line_start = target.line_start,
  }
  state.line_index = out.line_index
  state.last_refresh_ts = os.time()
  set_state(bufnr, state)
end

local function install_keymaps(bufnr)
  local organ = require("organ")
  local backlinks_cfg = require("organ.buf_config").read(nil, "backlinks") or {}
  -- Rule 2: keymaps = false disables all backlinks bindings.
  if backlinks_cfg.keymaps == false then
    return
  end
  local cfg = backlinks_cfg.keymaps or {}
  local function map(default_lhs, rhs, desc)
    local lhs = cfg[desc]
    if lhs == false then
      return
    end
    if lhs == nil then
      lhs = default_lhs
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = rhs,
    })
  end

  local function current_row()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    return (buf_state(bufnr).line_index or {})[lnum]
  end

  map("<CR>", function()
    local r = current_row()
    if not r then
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(r.source_headline.file_path))
    vim.api.nvim_win_set_cursor(0, { (r.source_headline.line_start or 0) + 1, 0 })
  end, "jump")

  -- gs/gv (consistent with the agenda buffer) instead of bare o/v —
  -- the latter shadow Vim's normal-mode `o` (open new line) and `v`
  -- (visual-character mode), causing user muscle memory to break.
  map("gs", function()
    local r = current_row()
    if not r then
      return
    end
    vim.cmd("split " .. vim.fn.fnameescape(r.source_headline.file_path))
    vim.api.nvim_win_set_cursor(0, { (r.source_headline.line_start or 0) + 1, 0 })
  end, "open_split")

  map("gv", function()
    local r = current_row()
    if not r then
      return
    end
    vim.cmd("vsplit " .. vim.fn.fnameescape(r.source_headline.file_path))
    vim.api.nvim_win_set_cursor(0, { (r.source_headline.line_start or 0) + 1, 0 })
  end, "open_vsplit")

  map("r", function()
    M.refresh(bufnr)
  end, "refresh")
  map("q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end, "close")

  map("g?", function()
    vim.api.nvim_echo({
      {
        table.concat({
          "organ.backlinks keymaps",
          "  <CR>  jump to source",
          "  gs    split + jump",
          "  gv    vsplit + jump",
          "  r     refresh",
          "  q     close",
          "  g?    this help",
        }, "\n"),
        "None",
      },
    }, true, {})
  end, "help")
end

function M.open(headline_id)
  register_highlights()

  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(bufnr, string.format("organ-backlinks://%d", bufnr))
  vim.bo[bufnr].filetype = "organ-backlinks"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false

  set_state(bufnr, { id = headline_id })

  local organ = require("organ")
  local cfg = (require("organ.buf_config").read(nil, "backlinks") or {})
  local debounce_ms = cfg.refresh_debounce_ms or 300

  local timer
  local listener = function(payload)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if payload and payload.skipped then
      return
    end
    if timer then
      timer:stop()
      timer:close()
    end
    local t = vim.loop.new_timer()
    timer = t
    t:start(
      debounce_ms,
      0,
      vim.schedule_wrap(function()
        if t:is_closing() then
          return
        end
        t:stop()
        t:close()
        if timer == t then
          timer = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          M.refresh(bufnr)
        end
      end)
    )
  end

  local events = require("organ.events")
  events.on("indexed", listener)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      events.off("indexed", listener)
      if timer then
        pcall(function()
          timer:stop()
          timer:close()
        end)
      end
    end,
  })

  install_keymaps(bufnr)
  vim.api.nvim_set_current_buf(bufnr)

  -- Winbar shows the target heading + incoming-link count.
  -- Statusline shows a tight keymap reference. Both are buffer/window
  -- local — never overwrite the user's global statusline / winbar.
  -- Opt out with cfg.backlinks.{winbar,statusline} = false; provide a
  -- string OR function to fully replace either.
  local bcfg = (require("organ.buf_config").read(nil, "backlinks") or {})
  require("organ.statusline").apply(bufnr, {
    winbar = bcfg.winbar,
    winbar_default = "backlinks_winbar",
    statusline = bcfg.statusline,
    statusline_default = "backlinks_statusline",
  })

  M.refresh(bufnr)
  return bufnr
end

-- Resolve the headline ID at cursor.  Returns nil + warns when not on
-- a headline, when the buffer has no file path, or when the row isn't
-- yet indexed.
local function id_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if ok and parser then
    parser:parse()
  end
  local node = vim.treesitter.get_node({ bufnr = bufnr, lang = "org" })
  while node and node:type() ~= "headline" do
    node = node:parent()
  end
  if not node then
    require("organ.notify").warn("no headline at cursor")
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    require("organ.notify").warn("current buffer has no file path")
    return nil
  end
  path = require("organ.path").canonical(path)
  local sr = select(1, node:range())
  for _, r in ipairs(require("organ.query").headlines({ file = path })) do
    if r.line_start == sr then
      return r.id
    end
  end
  require("organ.notify").warn("headline not indexed yet; save the file first")
  return nil
end

M.commands = {
  backlinks = {
    fn = function(cmd)
      local id = (cmd and cmd.args ~= "" and cmd.args) or id_at_cursor()
      if id then
        M.open(id)
      end
    end,
    nargs = "?",
    desc = "Show backlinks for the headline at cursor (or the given ID)",
  },
}

return M
