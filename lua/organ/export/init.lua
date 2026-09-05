-- Aggregator for buffer-export commands. Each backend (markdown / html /
-- latex / etc.) lives in its own sibling module; this module registers
-- the user-facing :Org export_* subcommands.

local M = {}

local function generic_export(cmd, mod_path, label)
  local exp = require(mod_path)
  local target = cmd.args ~= "" and cmd.args or nil
  if target then
    target = vim.fn.fnamemodify(target, ":p")
  end
  if target and vim.loop.fs_stat(target) and not cmd.bang then
    require("organ.notify").warn("file exists; use :Org " .. label .. "! to overwrite")
    return
  end
  -- Macro / SETUPFILE / INCLUDE expansion runs on every export (as it
  -- does in Emacs); the buffer's own path anchors relative includes.
  local name = vim.api.nvim_buf_get_name(0)
  local path, err = exp.export_buffer_to_file(0, target, {
    file_path = name ~= "" and name or nil,
  })
  if not path then
    require("organ.notify").error("organ: export failed: " .. tostring(err))
    return
  end
  require("organ.notify").info("organ: wrote " .. path)
end

M.commands = {
  ["export markdown"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.markdown", "export_markdown")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to markdown (CommonMark)",
  },
  ["export html"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.html", "export_html")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to a standalone HTML5 document",
  },
  ["export latex"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.latex", "export_latex")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to a standalone LaTeX document (article class)",
  },
  ["export beamer"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.beamer", "export_beamer")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to a Beamer presentation (.tex)",
  },
  ["export ascii"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.ascii", "export_ascii")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to plain text (.txt)",
  },
  ["export ics"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.ics", "export_ics")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export SCHEDULED/DEADLINE timestamps in the current buffer to RFC 5545 (.ics)",
  },
  ["export ics_all"] = {
    fn = function(cmd)
      local target = cmd.args ~= "" and cmd.args or nil
      if target then
        target = vim.fn.fnamemodify(target, ":p")
      end
      if not target then
        require("organ.notify").warn(":Org export ics_all requires an output path")
        return
      end
      if vim.loop.fs_stat(target) and not cmd.bang then
        require("organ.notify").warn("file exists; use :Org export ics_all! to overwrite")
        return
      end
      local path, err = require("organ.export.ics").export_query({}, target)
      if not path then
        require("organ.notify").error("organ: ics export failed: " .. tostring(err))
        return
      end
      require("organ.notify").info("organ: wrote " .. path)
    end,
    nargs = 1,
    complete = "file",
    bang = true,
    desc = "Export every indexed SCHEDULED/DEADLINE to a single .ics file",
  },
  ["export opml"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.opml", "export_opml")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer's outline structure to OPML 2.0 (.opml)",
  },
  ["export texinfo"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.texinfo", "export_texinfo")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to GNU Texinfo (.texi)",
  },
  ["export pdf"] = {
    fn = function(cmd)
      generic_export(cmd, "organ.export.pdf", "export_pdf")
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Export the current org buffer to PDF via LaTeX (requires pdflatex / xelatex / lualatex in PATH)",
  },
  ["table import"] = {
    fn = function(cmd)
      local path = cmd.args
      if not path or path == "" then
        require("organ.notify").warn(":Org table import requires a file path")
        return
      end
      local n, err = require("organ.table_io").import(0, vim.fn.line("."), path)
      if not n then
        require("organ.notify").error(err)
        return
      end
      require("organ.notify").info(("imported %d row(s) from %s"):format(n, path))
    end,
    nargs = 1,
    complete = "file",
    desc = "Import a CSV/TSV file as an org table at cursor",
  },
  ["table export"] = {
    fn = function(cmd)
      local path = cmd.args
      if not path or path == "" then
        require("organ.notify").warn(":Org table export requires a file path")
        return
      end
      local n, err = require("organ.table_io").export(0, vim.fn.line("."), path)
      if not n then
        require("organ.notify").error(err)
        return
      end
      require("organ.notify").info(("wrote %d row(s) to %s"):format(n, path))
    end,
    nargs = 1,
    complete = "file",
    desc = "Export the org table at cursor to CSV/TSV",
  },
}

return M
