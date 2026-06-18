-- Aggregator for buffer-import commands.  Mirrors organ.export: registers the
-- user-facing :Org import_* subcommands.  Markdown is the first importer;
-- each format converts source text -> organ AST -> org and opens the result.
local M = {}

-- Open `org_text` in a fresh scratch org buffer.
local function open_org(org_text)
  local lines = vim.split(org_text, "\n", { plain = true })
  -- Drop a single trailing empty line from the converter's trailing newline.
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = "org"
end

local function import_markdown(cmd)
  local path = (cmd.fargs and cmd.fargs[1]) or cmd.args
  if not path or path == "" then
    require("organ.notify").warn(":Org import markdown requires a file path")
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    require("organ.notify").warn("import markdown: file not readable: " .. path)
    return
  end
  local md = table.concat(vim.fn.readfile(path), "\n")
  local doc = require("organ.ast.from_md").parse(md)
  local org_text = require("organ.ast.to_org").render(doc)
  open_org(org_text)
end

M.commands = {
  ["import markdown"] = {
    fn = import_markdown,
    nargs = "1",
    complete = "file",
    bang = true,
    desc = "Import a Markdown (CommonMark/GFM) file into a new org buffer",
  },
}

return M
