-- Aggregator for buffer-import commands.  Mirrors organ.export: registers the
-- user-facing :Org import_* subcommands.  Markdown is the first importer;
-- each format converts source text -> organ AST -> org and opens the result.
local M = {}

-- Open `org_text` in a fresh org buffer.  When `suggested_name` is a path
-- that doesn't yet exist on disk (e.g. `notes.md` -> `notes.org`), name the
-- buffer that so `:w` has a sensible target -- but never shadow an existing
-- file.  The buffer stays unsaved either way (write only on save).
local function open_org(org_text, suggested_name)
  local lines = vim.split(org_text, "\n", { plain = true })
  -- Drop a single trailing empty line from the converter's trailing newline.
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = "org"
  if suggested_name and suggested_name ~= "" and vim.loop.fs_stat(suggested_name) == nil then
    pcall(vim.api.nvim_buf_set_name, 0, suggested_name)
  end
end

-- `:Org import markdown [path]`.  With a path, read that file; with no path,
-- convert the CURRENT buffer -- so you run it straight from the markdown
-- file you want to bring into org.
local function import_markdown(cmd)
  local path = (cmd.fargs and cmd.fargs[1]) or cmd.args
  local md, suggested
  if path and path ~= "" then
    if vim.fn.filereadable(path) ~= 1 then
      require("organ.notify").warn("import markdown: file not readable: " .. path)
      return
    end
    md = table.concat(vim.fn.readfile(path), "\n")
    suggested = vim.fn.fnamemodify(path, ":p:r") .. ".org"
  else
    local buf = vim.api.nvim_get_current_buf()
    md = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" then
      suggested = vim.fn.fnamemodify(name, ":p:r") .. ".org"
    end
  end
  local doc = require("organ.ast.from_md").parse(md, { extended_autolinks = true })
  local org_text = require("organ.ast.to_org").render(doc)
  open_org(org_text, suggested)
end

M.commands = {
  ["import markdown"] = {
    fn = import_markdown,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Import Markdown (CommonMark/GFM) into a new org buffer (arg: file; none: current buffer)",
  },
}

return M
