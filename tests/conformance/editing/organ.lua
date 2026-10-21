-- organ side of the editing conformance gate: runs each case's operation
-- (see emacs.el) through organ's commands in a real org buffer and prints
-- the result in the same shape as the Emacs side.

-- The harness stubs editor primitives (key input, cursor reads,
-- notifications, startinsert) around a command, hence the ignored warning.
-- luacheck: ignore 122

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

vim.cmd("filetype plugin on")
if not require("organ").cmd then
  vim.cmd("runtime plugin/organ.lua")
end

local organ = require("organ")
organ.setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local notify = require("organ.notify")
local BASE = vim.deepcopy(organ.config)
local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

-- Named settings a case enables with `# setup: NAME`; an empty table is a
-- setting organ has no counterpart for.
local SETUPS = {
  ["alpha-lists"] = {},
  ["odd-levels"] = { structure = { odd_levels_only = true } },
  ["respect-content"] = {},
  split = { meta_return = { split_headline = true, split_item = true } },
  ["adapt-t"] = { indent = { adapt_indentation = true } },
  ["adapt-hd"] = { indent = { adapt_indentation = "headline-data" } },
  ["modify-bullet"] = {},
  ["modify-bullet-dash"] = {},
  ["checkbox-flat"] = {},
  ["todo-flat"] = {},
  ["tags-column-40"] = { format = { headline = { tags_column = 40 } } },
}

-- Option runs: name -> settings.
local OPTIONS = {
  ["planning-flush"] = { todo = { planning_indent = 0 } },
}

local VIS_OPS = {
  ["sparse-todo"] = true,
  ["sparse-todo-keyword"] = true,
  ["sparse-tag"] = true,
  ["sparse-occur"] = true,
  ["sparse-match"] = true,
  ["sparse-match-todo"] = true,
  startup = true,
  overview = true,
  ["overview-cycle"] = true,
  tab = true,
  ["global-cycle"] = true,
  speed = true,
}

local VALUE_OPS = {
  ["allowed-values"] = true,
  ["inherited-property"] = true,
  ["inherited-property-all"] = true,
  ["inherited-tags"] = true,
  ["org-indent"] = true,
  narrow = true,
}

local UNCURSORED_OPS = { format = true, fill = true }

local NO_COMMAND = "! no organ command"

local function words(s)
  local out, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' then
      local w, j = {}, i + 1
      while j <= #s and s:sub(j, j) ~= '"' do
        if s:sub(j, j) == "\\" then
          j = j + 1
        end
        w[#w + 1] = s:sub(j, j)
        j = j + 1
      end
      out[#out + 1] = table.concat(w)
      i = j + 1
    else
      local j = s:find("%s", i) or #s + 1
      out[#out + 1] = s:sub(i, j - 1)
      i = j
    end
  end
  return out
end

local function split_header(lines)
  local headers, i = {}, 1
  while lines[i] do
    local k, v = lines[i]:match("^# ([a-z-]+): ?(.*)$")
    if not k then
      break
    end
    headers[k] = v
    i = i + 1
  end
  return headers, vim.list_slice(lines, i)
end

local function merge_into(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge_into(dst[k], v)
    else
      dst[k] = vim.deepcopy(v)
    end
  end
end

local function reset_config(extra)
  local cfg = organ.config
  for k in pairs(cfg) do
    cfg[k] = nil
  end
  for k, v in pairs(vim.deepcopy(BASE)) do
    cfg[k] = v
  end
  for _, t in ipairs(extra) do
    merge_into(cfg, t)
  end
end

-- Remove the @@C@@ / @@M@@ markers; return cursor and mark as
-- { line, byte col } (mark nil when absent).
local function take_markers(lines)
  local found = {}
  for _, m in ipairs({ "@@M@@", "@@C@@" }) do
    for i, l in ipairs(lines) do
      local s = l:find(m, 1, true)
      if s then
        found[m] = { i, s - 1 }
        lines[i] = l:sub(1, s - 1) .. l:sub(s + 5)
        break
      end
    end
  end
  local cur, mark = found["@@C@@"] or { 1, 0 }, found["@@M@@"]
  if mark and mark[1] == cur[1] and mark[2] > cur[2] then
    mark[2] = mark[2] - 5
  end
  return cur, mark
end

local function C(path, args)
  local e = organ.cmd(path)
  if not (e and e.fn) then
    error("no subcommand " .. path)
  end
  args = args or ""
  e.fn({ args = args, fargs = words(args), range = 0 })
end

local function cursor_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

-- organ's returned error is a refusal, unlike an error organ raises.
local function fail_on(err)
  if err then
    error({ refusal = err })
  end
end

local function headline_rows(bufnr)
  local rows = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:match("^%*+%s") or l:match("^%*+$") then
      rows[#rows + 1] = i
    end
  end
  return rows
end

local function region_lines(cur, mark)
  local s, e = cur[1], mark and mark[1] or cur[1]
  if e < s then
    s, e = e, s
  end
  if mark and mark[2] == 0 and e > s then
    e = e - 1
  end
  return s, e
end

local function cycle_n(n)
  for _ = 1, n do
    require("organ.fold").cycle(0, 1)
  end
end

local OPS = {}

OPS["meta-return"] = function()
  C("meta_return")
end
OPS["insert-todo"] = function()
  C("insert_todo")
end
OPS["insert-heading-rc"] = function()
  C("insert_heading_respect_content")
end
OPS["insert-todo-rc"] = function()
  C("insert_todo_heading_respect_content")
end
OPS["promote"] = function()
  C("promote")
end
OPS["demote"] = function()
  C("demote")
end
OPS["promote-headline"] = function()
  C("promote_headline")
end
OPS["demote-headline"] = function()
  C("demote_headline")
end
OPS["demote-region"] = function(_, cur, mark)
  local s, e = region_lines(cur, mark)
  fail_on(require("organ.structure").demote_region({ start_line = s, end_line = e }))
end
OPS["move-up"] = function()
  C("move_up")
end
OPS["move-down"] = function()
  C("move_down")
end
OPS["toggle-comment"] = function()
  C("toggle_comment")
end
local function cut_paste(cmd)
  C(cmd)
  local r = vim.fn.search("PP", "cw")
  local l = vim.api.nvim_get_current_line()
  local c = l:find("PP", 1, true)
  vim.api.nvim_set_current_line(l:sub(1, c - 1) .. l:sub(c + 2))
  vim.api.nvim_win_set_cursor(0, { r, c - 1 })
  C("paste_subtree")
end
OPS["cut-paste"] = function()
  cut_paste("cut_subtree")
end
OPS["copy-paste"] = function()
  cut_paste("copy_subtree")
end
OPS["narrow"] = function()
  C("narrow_to_subtree")
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end
OPS["sort-entries"] = function(args)
  if args[1] == "r" then
    C("sort_entries", "property " .. args[2])
  else
    C("sort_entries", args[1])
  end
end
OPS["cycle-bullet"] = function(args)
  C("list cycle_bullet", args[1] or "")
end
OPS["item-indent"] = function()
  C("demote_headline")
end
OPS["item-indent-tree"] = function()
  C("demote")
end
OPS["item-outdent-tree"] = function()
  C("promote")
end
OPS["item-indent-region"] = function(_, cur, mark)
  local s, e = region_lines(cur, mark)
  if not require("organ.list").shift_region(0, s, e, "demote") then
    error("region not shifted", 0)
  end
end
OPS["list-repair"] = function()
  C("list repair")
end
OPS["format-list"] = function()
  C("format")
end
OPS["list-sort"] = function(args)
  local keys = { a = "alpha", n = "numeric" }
  C("list sort", keys[args[1]] or args[1])
end
OPS["item-move-down"] = function()
  C("move_down")
end
OPS["list-to-subtree"] = function()
  C("list to_subtree")
end
OPS["toggle-checkbox"] = function()
  C("toggle_checkbox")
end
OPS["toggle-checkbox-region"] = function(_, cur, mark)
  local s, e = region_lines(cur, mark)
  vim.cmd(s .. "," .. e .. "Org toggle_checkbox")
end
OPS["update-statistics"] = function()
  C("update_statistics")
end
OPS["todo"] = function()
  C("todo")
end
OPS["set-property"] = function(args)
  fail_on(require("organ.property").set(0, cursor_line(), args[1], args[2]))
end
OPS["delete-property"] = function(args)
  fail_on(require("organ.property").delete(0, cursor_line(), args[1]))
end
OPS["allowed-values"] = function(args)
  local v = require("organ.property").allowed_values(0, cursor_line(), args[1])
  if not v or #v == 0 then
    return { "nil" }
  end
  local out = {}
  for _, s in ipairs(v) do
    out[#out + 1] = string.format("%q", s)
  end
  return out
end
OPS["inherited-property"] = function(args)
  local el = require("organ.element")
  local h = el.headline_at(0, cursor_line() - 1)
  local v = h and el.property_value_inherited(0, h.line_start, args[1])
  return { v and string.format("%q", v) or "nil" }
end
OPS["inherited-property-all"] = function(args)
  local el = require("organ.element")
  local out = {}
  for _, row in ipairs(headline_rows(0)) do
    out[#out + 1] = row .. "\t" .. (el.property_value_inherited(0, row - 1, args[1]) or "")
  end
  return out
end
OPS["inherited-tags"] = function()
  local path = vim.api.nvim_buf_get_name(0)
  vim.cmd("silent write!")
  require("organ.indexer").index_file_sync(path)
  local rows = require("organ.query").headlines({ file = path, include_inherited_tags = true })
  table.sort(rows, function(a, b)
    return a.line_start < b.line_start
  end)
  local out = {}
  for _, r in ipairs(rows) do
    local tags = vim.deepcopy(r.tags or {})
    table.sort(tags)
    out[#out + 1] = (r.line_start + 1) .. "\t" .. table.concat(tags, ",")
  end
  return out
end
OPS["fast-tags"] = function(args)
  local q = {}
  for ch in (args[1] .. "\r"):gmatch(".") do
    q[#q + 1] = ch
  end
  local i = 0
  local real = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    i = i + 1
    return q[i] or "\27"
  end
  local ok, err = pcall(C, "set_tags")
  vim.fn.getcharstr = real
  if not ok then
    error(err, 0)
  end
end
OPS["set-tags"] = function(args)
  local t = {}
  for x in (args[1] or ""):gmatch("[^:]+") do
    t[#t + 1] = x
  end
  fail_on(require("organ.tag_writer").write(0, cursor_line(), t))
end
OPS["align-tags"] = function()
  C("format")
end
OPS["sparse-todo"] = function()
  C("sparse_tree todo")
end
OPS["sparse-todo-keyword"] = function(args)
  C("sparse_tree todo", args[1])
end
OPS["sparse-tag"] = function(args)
  C("sparse_tree tag", args[1])
end
OPS["sparse-occur"] = function(args)
  C("sparse_tree regex", args[1])
end
OPS["sparse-match"] = function(args)
  C("sparse_tree match", args[1])
end
OPS["sparse-match-todo"] = function(args)
  C("sparse_tree match", args[1] .. "/!")
end
OPS["startup"] = function() end
OPS["overview"] = function()
  require("organ.fold").apply_overview(0, 0)
end
OPS["overview-cycle"] = function(args)
  require("organ.fold").apply_overview(0, 0)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  cycle_n(tonumber(args[1]))
end
OPS["tab"] = function()
  require("organ.fold").cycle(0, cursor_line())
end
OPS["global-cycle"] = function()
  require("organ.fold").cycle_global(0)
end
OPS["emphasize"] = function(args, cur, mark)
  local ch = args[1] == "SPC" and " " or args[1]
  if mark then
    local s, e = cur[2] + 1, mark[2]
    if mark[2] < cur[2] then
      s, e = mark[2] + 1, cur[2]
    end
    fail_on(require("organ.emphasize").span(0, cur[1], s, e, ch))
  else
    C("emphasize", ch)
  end
end
OPS["fill"] = function()
  vim.bo.textwidth = 70
  vim.cmd("normal! gqip")
end
-- tempo expands in insert mode, where the cursor sits after the typed
-- key; normal mode cannot place it there, so the cursor read is moved
-- to the end of the trigger line.
OPS["tempo"] = function()
  local r = cursor_line()
  local real = vim.api.nvim_win_get_cursor
  vim.api.nvim_win_get_cursor = function(w)
    local c = real(w)
    if c[1] == r then
      return { r, #vim.api.nvim_get_current_line() }
    end
    return c
  end
  local ok, res = pcall(require("organ.tempo").expand, 0)
  vim.api.nvim_win_get_cursor = real
  if not ok then
    error(res, 0)
  end
end
OPS["priority-shiftup"] = function()
  C("decrement")
end
OPS["priority-shiftdown"] = function()
  C("increment")
end
OPS["timestamp-shiftup"] = function()
  C("increment")
end
OPS["timestamp-shiftdown"] = function()
  C("decrement")
end
OPS["priority-up"] = function()
  require("organ.inline_edit").raise_priority(0, cursor_line())
end
OPS["priority-down"] = function()
  require("organ.inline_edit").lower_priority(0, cursor_line())
end
OPS["format"] = function()
  C("format")
end
local function ranged(cmd, cur, mark)
  if mark then
    local s, e = region_lines(cur, mark)
    vim.cmd(s .. "," .. e .. "Org " .. cmd)
  else
    C(cmd)
  end
end
OPS["toggle-heading"] = function(_, cur, mark)
  ranged("toggle_heading", cur, mark)
end
OPS["toggle-item"] = function(_, cur, mark)
  ranged("toggle_item", cur, mark)
end
OPS["indent-region"] = function()
  vim.cmd("silent normal! gg=G")
end
OPS["org-indent"] = function()
  local indent = require("organ.indent")
  organ.config.indent.enabled = true
  indent.attach(0)
  vim.cmd("redraw")
  local out = {}
  for l = 0, vim.api.nvim_buf_line_count(0) - 1 do
    local w = 0
    local marks = vim.api.nvim_buf_get_extmarks(
      0,
      indent._ns,
      { l, 0 },
      { l, -1 },
      { details = true }
    )
    for _, m in ipairs(marks) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        w = w + vim.fn.strdisplaywidth(chunk[1])
      end
    end
    out[#out + 1] = "lp=" .. w .. "|" .. vim.api.nvim_buf_get_lines(0, l, l + 1, false)[1]
  end
  return out
end
OPS["speed"] = function(args)
  local action = (organ.config.speed.commands or {})[args[1]]
  if not action then
    return NO_COMMAND
  end
  require("organ.speed").dispatch(action)
end
for _, op in ipairs({
  "insert-subheading",
  "mark-subtree",
  "toggle-checkbox-remove",
  "structure-template",
}) do
  OPS[op] = function()
    return NO_COMMAND
  end
end

-- Visible lines: a line inside a closed fold (other than the fold's own
-- first line, which shows as the fold text) or covered by a conceal_lines
-- extmark is hidden.
local function vis_lines(bufnr)
  vim.cmd("redraw")
  local out = {}
  for l, text in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local fc = vim.fn.foldclosed(l)
    local hidden = fc ~= -1 and fc ~= l
    if not hidden then
      local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        -1,
        { l - 1, 0 },
        { l - 1, -1 },
        { details = true, overlap = true }
      )
      for _, m in ipairs(marks) do
        if m[4].conceal_lines == "" then
          hidden = true
        end
      end
    end
    out[#out + 1] = (hidden and "H|" or "V|") .. text
  end
  return out
end

local function close_extra_windows(keep)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= keep and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

local M = {}

function M.render(path, option)
  local headers, lines = split_header(vim.fn.readfile(path))
  local op_spec = words(headers.op or "")
  local op = table.remove(op_spec, 1)
  if option and not vim.tbl_contains(words(headers.options or ""), option) then
    return "n/a\n"
  end
  local extra = {}
  for _, s in ipairs(words(headers.setup or "")) do
    extra[#extra + 1] = assert(SETUPS[s], "unknown setup " .. s)
  end
  if option then
    extra[#extra + 1] = OPTIONS[option]
  end
  reset_config(extra)

  local cur, mark = take_markers(lines)
  local file = TMP .. "/" .. vim.fn.fnamemodify(path, ":t")
  vim.fn.writefile(lines, file)
  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "org"
  vim.wo[win].virtualedit = "onemore"
  vim.wait(20)
  pcall(vim.api.nvim_win_set_cursor, 0, cur)

  local status
  local saved =
    { error = notify.error, warn = notify.warn, info = notify.info, vim_notify = vim.notify }
  notify.error = function()
    status = status or "! error"
  end
  notify.warn = notify.error
  notify.info = function() end
  vim.notify = function(_, level)
    if level and level >= vim.log.levels.WARN then
      status = status or "! error"
    end
  end
  local insert
  local real_cmd = vim.cmd
  vim.cmd = setmetatable({}, {
    __index = real_cmd,
    __call = function(_, c, ...)
      if type(c) == "string" and c:match("^startinsert") then
        insert = c
        return
      end
      return real_cmd(c, ...)
    end,
  })
  local ok, result = pcall(assert(OPS[op], "unknown op " .. tostring(op)), op_spec, cur, mark)
  vim.cmd = real_cmd
  vim.wait(20)
  notify.error, notify.warn, notify.info = saved.error, saved.warn, saved.info
  vim.notify = saved.vim_notify
  if not ok and type(result) == "table" and result.refusal then
    status = "! error"
    result = nil
  elseif not ok then
    status = "! crash: "
      .. tostring(result)
        :gsub("%S*%.lua:%d+: ", "")
        :gsub('%[string "[^"]*"%]:%d+: ', "")
        :gsub("\n", " ")
    result = nil
  elseif status then
    result = nil
  elseif result == NO_COMMAND then
    status = NO_COMMAND
    result = nil
  end

  local out = {}
  if status then
    out[1] = status
  end
  if VALUE_OPS[op] then
    vim.list_extend(out, result or {})
  else
    local final = VIS_OPS[op] and vis_lines(bufnr)
      or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.list_extend(out, final)
    local c = vim.api.nvim_win_get_cursor(vim.api.nvim_win_is_valid(win) and win or 0)
    local text = vim.api.nvim_buf_get_lines(bufnr, c[1] - 1, c[1], false)[1] or ""
    if not UNCURSORED_OPS[op] then
      local col = insert == "startinsert!" and #text or c[2]
      col = vim.fn.strchars(text:sub(1, col))
      out[#out + 1] = "--- point"
      out[#out + 1] = string.format("%d:%d", c[1], col)
    end
  end

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  close_extra_windows(win)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= bufnr and vim.api.nvim_buf_get_name(b):find(TMP, 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose!")
  end
  os.remove(file)
  return table.concat(out, "\n") .. "\n"
end

return M
