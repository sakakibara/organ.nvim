-- Canonical structural dump from organ's tree-sitter parse.  Counterpart
-- to scripts/emacs-element-dump.el, which documents the record format and
-- the configuration both sides pin; scripts/diff-against-emacs.sh diffs
-- the two.
--
-- Usage:
--   nvim --headless -l scripts/organ-element-dump.lua <listfile>

local args = arg or {}
local listfile = args[1]
if not listfile then
  io.stderr:write("usage: organ-element-dump.lua <listfile>\n")
  os.exit(2)
end

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/organ")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = {
    sequence = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "|", "DONE", "CANCELLED" },
  },
})

local extract = require("organ.indexer.extract")
local parser_path = require("organ.buf_config").read(nil, "parser_path")

local function escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\t", "\\t")
  s = s:gsub("\n", "\\n")
  return s
end

local out = {}

local function emit(line)
  out[#out + 1] = line
end

local list = io.open(listfile, "r")
if not list then
  io.stderr:write("organ-element-dump: cannot read " .. listfile .. "\n")
  os.exit(2)
end

for path in list:lines() do
  if path ~= "" then
    emit("F\t" .. path)
    local handle = io.open(path, "r")
    if not handle then
      io.stderr:write("organ-element-dump: cannot read " .. path .. "\n")
      os.exit(2)
    end
    local source = handle:read("*a")
    handle:close()
    local ok, headlines = pcall(extract.extract, source, path, parser_path)
    if not ok then
      io.stderr:write("organ-element-dump: " .. path .. ": " .. tostring(headlines) .. "\n")
      os.exit(2)
    end
    for _, headline in ipairs(headlines) do
      if headline.level and headline.level > 0 then
        emit(table.concat({
          "H",
          tostring(headline.level),
          escape(headline.todo_state),
          escape(headline.priority),
          escape(table.concat(headline.tags or {}, ",")),
          escape(headline.title),
        }, "\t"))
        if headline.commented == 1 then
          emit("X\tCOMMENT")
        end
        for _, tag in ipairs(headline.tags or {}) do
          if tag == "ARCHIVE" then
            emit("X\tARCHIVE")
            break
          end
        end
        if headline.scheduled then
          emit("S\t" .. escape(headline.scheduled))
        end
        if headline.deadline then
          emit("D\t" .. escape(headline.deadline))
        end
        if headline.closed then
          emit("C\t" .. escape(headline.closed))
        end
        for _, property in ipairs(headline.properties or {}) do
          emit("P\t" .. escape(property.key) .. "\t" .. escape(property.value))
        end
      end
    end
  end
end
list:close()

io.write(table.concat(out, "\n"))
io.write("\n")
