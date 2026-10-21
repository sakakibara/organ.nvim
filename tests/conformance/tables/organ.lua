-- organ side of the tables conformance gate: runs each case's operation
-- (see emacs.el) through organ's table commands and prints the buffer in
-- the same shape as the Emacs side.

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

pcall(function()
  require("organ").setup({})
end)

local tbl = require("organ.table")
local tio = require("organ.table_io")
local notify = require("organ.notify")

local RAW_OPS = { align = true, format = true, tab = true, ["shift-tab"] = true, import = true }
local CURSOR_OPS = { tab = true, ["shift-tab"] = true }
local IMPORT_EXT = { csv = true, tsv = true, txt = true, dat = true }

-- Option runs: name -> { path within organ.config, value }.
local OPTIONS = {
  emphasis = { { "emphasis", "enabled" }, true },
}

local function header(lines, key)
  local v
  for _, l in ipairs(lines) do
    if not l:match("^# %l+:") then
      break
    end
    v = v or l:match("^# " .. key .. ": *(.*)$")
  end
  if not v then
    return nil
  end
  local words = {}
  for w in v:gmatch("%S+") do
    words[#words + 1] = w
  end
  return words
end

local function goto_table()
  if not vim.api.nvim_get_current_line():match("^%s*|") then
    vim.fn.search("^\\s*|")
  end
end

local function cells(line)
  local s = line:gsub("^[ \t]*|", ""):gsub("|[ \t]*$", "")
  local out = {}
  for c in (s .. "|"):gmatch("([^|]*)|") do
    out[#out + 1] = c:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  end
  return table.concat(out, "\t")
end

local function render_lines(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("^[ \t]*|%-") then
      out[#out + 1] = "|-"
    elseif l:match("^[ \t]*|") then
      out[#out + 1] = "|" .. cells(l)
    else
      out[#out + 1] = l
    end
  end
  return out
end

local function run_op(op, args, cases_dir, bufnr)
  local line = vim.fn.line(".")
  if op == "recalc" or op == "iterate" then
    goto_table()
    tbl.eval_formulas(bufnr)
  elseif op == "recalc-line" or op == "ctrl-c-ctrl-c" then
    tbl.eval_formulas(bufnr)
  elseif op == "align" then
    goto_table()
    tbl.realign(bufnr, vim.fn.line("."))
  elseif op == "format" then
    require("organ.format").format_buffer(bufnr)
  elseif op == "tab" then
    tbl.tab(bufnr)
  elseif op == "shift-tab" then
    tbl.shift_tab(bufnr)
  elseif op == "insert-row-above" then
    tbl.insert_row_above(bufnr)
  elseif op == "insert-row-below" then
    tbl.insert_row_below(bufnr)
  elseif op == "delete-row" then
    tbl.delete_row(bufnr)
  elseif op == "move-row-up" then
    tbl.move_row_up(bufnr)
  elseif op == "move-row-down" then
    tbl.move_row_down(bufnr)
  elseif op == "insert-column-left" then
    tbl.insert_column_left(bufnr)
  elseif op == "delete-column" then
    tbl.delete_column(bufnr)
  elseif op == "move-column-left" then
    tbl.move_column_left(bufnr)
  elseif op == "move-column-right" then
    tbl.move_column_right(bufnr)
  elseif op == "sort" then
    local key = args[1]
    tbl.sort_by_current_column(bufnr, key:match("%u") and "desc" or "asc")
  elseif op == "import" then
    local n, err = tio.import(bufnr, line, cases_dir .. "/" .. args[1])
    if not n then
      notify.error(err)
    end
  elseif op == "export" then
    goto_table()
    local tmp = vim.fn.tempname() .. "." .. args[1]
    local n, err = tio.export(bufnr, vim.fn.line("."), tmp)
    if not n then
      notify.error(err)
      return nil
    end
    local f = io.open(tmp, "rb")
    local body = f and f:read("*a") or ""
    if f then
      f:close()
    end
    os.remove(tmp)
    return body
  else
    error("conformance: unknown op " .. op)
  end
end

local function split(text)
  local t = vim.split(text, "\n", { plain = true })
  if t[#t] == "" then
    t[#t] = nil
  end
  return t
end

local function set_option(option, value)
  local spec = OPTIONS[option]
  local cfg = require("organ").config
  local parent = cfg
  for i = 1, #spec[1] - 1 do
    parent = parent[spec[1][i]]
  end
  local key = spec[1][#spec[1]]
  local old = parent[key]
  parent[key] = value == nil and spec[2] or value
  return old
end

local M = {}

function M.render(path, option)
  local cases_dir = vim.fn.fnamemodify(path, ":h")
  local import_case = IMPORT_EXT[vim.fn.fnamemodify(path, ":e")]
  local lines = import_case and { "" } or vim.fn.readfile(path)
  local op_spec = import_case and { "import", vim.fn.fnamemodify(path, ":t") }
    or header(lines, "op")
    or { "recalc" }
  local op = table.remove(op_spec, 1)
  if option and not vim.tbl_contains(header(lines, "options") or {}, option) then
    return "n/a\n"
  end

  local cl, cc = 1, 0
  for i, l in ipairs(lines) do
    local s = l:find("@@C@@", 1, true)
    if s then
      cl, cc = i, s - 1
      lines[i] = l:sub(1, s - 1) .. l:sub(s + 5)
      break
    end
  end

  local old_option = option and set_option(option)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "org"
  vim.api.nvim_win_set_cursor(0, { cl, cc })

  local status
  local saved = { error = notify.error, warn = notify.warn }
  notify.error = function()
    status = status or "! error"
  end
  notify.warn = notify.error
  local ok, result = pcall(run_op, op, op_spec, cases_dir, bufnr)
  notify.error, notify.warn = saved.error, saved.warn
  if not ok then
    status = "! crash: "
      .. tostring(result)
        :gsub("%S*%.lua:%d+: ", "")
        :gsub('%[string "[^"]*"%]:%d+: ', "")
        :gsub("\n", " ")
    result = nil
  end
  if option then
    set_option(option, old_option)
  end

  local final = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur = vim.api.nvim_win_get_cursor(0)
  local col = vim.fn.strchars((final[cur[1]] or ""):sub(1, cur[2]))
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local out = {}
  if status then
    out[1] = status
  end
  vim.list_extend(out, render_lines(final))
  if CURSOR_OPS[op] then
    out[#out + 1] = string.format("@ %d:%d", cur[1], col)
  end
  if result then
    out[#out + 1] = "--- export"
    vim.list_extend(out, split(result))
  end
  if RAW_OPS[op] then
    out[#out + 1] = "--- raw"
    vim.list_extend(out, final)
  end
  return table.concat(out, "\n") .. "\n"
end

return M
