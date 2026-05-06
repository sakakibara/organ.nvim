-- Directive (`#+KEYWORD:`) completion source.
--
-- Trigger: line starts with `#+` and the cursor is in the keyword
-- portion (before the `:`). Surfaces standard org directives plus
-- block openers (`begin_src`, `begin_quote`, etc.).

local M = {}

-- Standard org directive keywords. Grouped by purpose for the
-- documentation field; the actual completion is flat.
local DIRECTIVES = {
  -- File-level
  { name = "TITLE", suffix = ": ", doc = "Document title" },
  { name = "AUTHOR", suffix = ": ", doc = "Author" },
  { name = "DATE", suffix = ": ", doc = "Date" },
  { name = "EMAIL", suffix = ": ", doc = "Email" },
  { name = "FILETAGS", suffix = ": ", doc = "Tags applied to every headline" },
  { name = "CATEGORY", suffix = ": ", doc = "Default agenda category" },
  { name = "OPTIONS", suffix = ": ", doc = "Export options" },
  { name = "DESCRIPTION", suffix = ": ", doc = "Description" },
  { name = "KEYWORDS", suffix = ": ", doc = "Keywords" },
  { name = "LANGUAGE", suffix = ": ", doc = "Language" },
  { name = "SETUPFILE", suffix = ": ", doc = "Include another file's setup" },
  { name = "STARTUP", suffix = ": ", doc = "Per-file startup options" },
  { name = "TODO", suffix = ": ", doc = "TODO keyword sequence" },
  { name = "TAGS", suffix = ": ", doc = "Tag dictionary" },
  { name = "PRIORITIES", suffix = ": ", doc = "Priority cookie range" },
  { name = "ARCHIVE", suffix = ": ", doc = "Archive location pattern" },
  { name = "BIBLIOGRAPHY", suffix = ": ", doc = "Bibliography file path" },
  { name = "CITE_EXPORT", suffix = ": ", doc = "Citation processor" },
  { name = "PROPERTY", suffix = ": ", doc = "File-level property default" },
  { name = "LINK", suffix = ": ", doc = "Link abbreviation" },
  { name = "MACRO", suffix = ": ", doc = "Macro definition" },
  { name = "INCLUDE", suffix = ": ", doc = "Include another file" },
  { name = "ATTR_HTML", suffix = ": ", doc = "HTML export attributes" },
  { name = "ATTR_LATEX", suffix = ": ", doc = "LaTeX export attributes" },
  { name = "ATTR_ORG", suffix = ": ", doc = "Org export attributes" },
  { name = "NAME", suffix = ": ", doc = "Name an element for cross-reference" },
  { name = "CAPTION", suffix = ": ", doc = "Caption an element" },
  { name = "HEADER", suffix = ": ", doc = "Block header arguments" },
  { name = "PLOT", suffix = ": ", doc = "Plot table data" },
  { name = "TBLNAME", suffix = ": ", doc = "Name a table" },
  { name = "RESULTS", suffix = ": ", doc = "Babel results marker" },
  { name = "CALL", suffix = ": ", doc = "Call a named babel block" },
  { name = "LATEX_CLASS", suffix = ": ", doc = "LaTeX document class" },
  { name = "LATEX_HEADER", suffix = ": ", doc = "Extra LaTeX preamble" },
  { name = "HTML_HEAD", suffix = ": ", doc = "Extra <head> content" },
  -- Block openers (paired closer is appended on insert).
  { name = "begin_src", suffix = " ", doc = "Source code block", block = "src" },
  { name = "begin_example", suffix = "\n", doc = "Verbatim example block", block = "example" },
  { name = "begin_quote", suffix = "\n", doc = "Quote block", block = "quote" },
  { name = "begin_verse", suffix = "\n", doc = "Verse block", block = "verse" },
  { name = "begin_center", suffix = "\n", doc = "Centered block", block = "center" },
  { name = "begin_export", suffix = " ", doc = "Export block", block = "export" },
  { name = "begin_comment", suffix = "\n", doc = "Comment block", block = "comment" },
}

-- Returns the partial directive name (after `#+`) or nil.
function M.cursor_partial(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if row == nil or col == nil then
    local pos = vim.api.nvim_win_get_cursor(0)
    row = row or pos[1]
    col = col or pos[2]
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)
  -- `^#%+(WORD)` where word may be empty (just typed `#+`).
  local partial = before:match("^#%+([%w_]*)$")
  if not partial then
    return nil
  end
  return partial
end

function M.completion_items(partial)
  local q = (partial or "")
  local q_upper = q:upper()
  local q_lower = q:lower()
  local items = {}
  for _, d in ipairs(DIRECTIVES) do
    -- Match either case-insensitively (block names are lowercase by
    -- convention; directive names uppercase).
    if
      q == ""
      or d.name:upper():find(q_upper, 1, true) == 1
      or d.name:lower():find(q_lower, 1, true) == 1
    then
      local insert
      if d.block then
        -- begin_src / begin_quote / etc. — emit the opener AND the
        -- matching closer with a blank body line in between. Cursor
        -- ends up on the body line after insertion (caller responsibility).
        if d.block == "src" or d.block == "export" then
          insert = string.format("%s ", d.name)
        else
          insert = string.format("%s\n\n#+end_%s", d.name, d.block)
        end
      else
        insert = d.name .. d.suffix
      end
      items[#items + 1] = {
        label = "#+" .. d.name,
        insertText = insert,
        filterText = d.name,
        kind = d.block and "Snippet" or "Keyword",
        detail = d.doc,
      }
    end
  end
  return items
end

return M
