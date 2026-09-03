-- extract() recognises TODO keywords from the file's `#+TODO:` lines
-- (which replace the configured set, as in Emacs) or, absent those,
-- from `todo.sequence` config; tags may contain non-ASCII word chars.
-- Run via: nvim --headless -l tests/indexer_todo_keywords_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/k.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "STARTED", "|", "DONE" } },
})

local extract = require("organ.indexer.extract")
local parser_path = require("organ.defaults").parser_path

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function by_line(src)
  local out = {}
  for _, h in ipairs(extract.extract(src, tmp .. "/x.org", parser_path)) do
    out[h.line_start + 1] = h
  end
  return out
end

-- Configured sequence, no file-level directive.
do
  local h = by_line(table.concat({
    "* STARTED Work :work:",
    "* TODO Plain",
    "* NEXT Not configured",
    "",
  }, "\n"))
  check("config keyword STARTED", h[1].todo_state == "STARTED", vim.inspect(h[1]))
  check("config title after keyword", h[1].title == "Work", vim.inspect(h[1]))
  check("config keyword TODO", h[2].todo_state == "TODO", vim.inspect(h[2]))
  check("unconfigured NEXT is title text", h[3].todo_state == nil, vim.inspect(h[3]))
  check("unconfigured NEXT title", h[3].title == "NEXT Not configured", vim.inspect(h[3]))
end

-- File-level #+TODO replaces the configured sequence.
do
  local h = by_line(table.concat({
    "#+TODO: INBOX(i) STARTED | ARCHIVED(a!)",
    "* INBOX Sort mail",
    "* ARCHIVED Old",
    "* TODO Plain",
    "",
  }, "\n"))
  check("file keyword INBOX (annotation stripped)", h[2].todo_state == "INBOX", vim.inspect(h[2]))
  check("file keyword ARCHIVED", h[3].todo_state == "ARCHIVED", vim.inspect(h[3]))
  check("global TODO not a keyword in this file", h[4].todo_state == nil, vim.inspect(h[4]))
  check("global TODO stays in title", h[4].title == "TODO Plain", vim.inspect(h[4]))
end

-- Tags: `[[:alnum:]_@#%]+` (Emacs `org-tag-re`) includes non-ASCII.
do
  local h = by_line("* Task one :仕事:home:\n")
  check("non-ASCII tag title", h[1].title == "Task one", vim.inspect(h[1]))
  check(
    "non-ASCII tags parsed",
    vim.deep_equal(h[1].tags, { "仕事", "home" }),
    vim.inspect(h[1].tags)
  )
end

-- Without a `|`, the last keyword of a `#+TODO` line is the done state
-- (Emacs `org-set-regexps-and-options`).
do
  local function done_map(src)
    local out = {}
    for _, r in ipairs(extract.scan_todo_keywords(src)) do
      out[r.keyword] = r.is_done
    end
    return out
  end
  local m = done_map("#+TODO: A B\n#+TODO: X\n#+TODO: P Q | R\n")
  check("bar-less: first keyword active", m.A == 0, vim.inspect(m))
  check("bar-less: last keyword done", m.B == 1, vim.inspect(m))
  check("bar-less: lone keyword done", m.X == 1, vim.inspect(m))
  check("with bar: active keywords", m.P == 0 and m.Q == 0, vim.inspect(m))
  check("with bar: done keyword", m.R == 1, vim.inspect(m))
end

-- A buffer source honours its `#+TODO` lines like the string source.
do
  local src = "#+TODO: WAIT | FIN\n* WAIT one\n* FIN two\n* TODO three\n"
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(src, "\n"))
  vim.bo[b].filetype = "org"
  local ok, parser = pcall(vim.treesitter.get_parser, b, "org")
  check("buffer parser available", ok and parser ~= nil)
  local h = {}
  for _, r in ipairs(extract.extract(b, tmp .. "/b.org", parser_path)) do
    h[r.line_start + 1] = r
  end
  check("bufnr file keyword WAIT", h[2].todo_state == "WAIT", vim.inspect(h[2]))
  check("bufnr file keyword FIN", h[3].todo_state == "FIN", vim.inspect(h[3]))
  check("bufnr title after keyword", h[3].title == "two", vim.inspect(h[3]))
  check("bufnr global TODO stays in title", h[4].title == "TODO three", vim.inspect(h[4]))
end

vim.fn.delete(tmp, "rf")
if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("indexer_todo_keywords_test: PASS")
os.exit(0)
