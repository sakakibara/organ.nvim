-- Edit a `#+begin_src LANG ... #+end_src` block in a dedicated buffer
-- with the language's filetype, mirroring Emacs's `org-edit-special`
-- (`C-c '`).  Saving / closing the edit buffer writes the body back to
-- the source org buffer, preserving indentation.
--
-- Public API:
--   M.open(bufnr?, line?)   open the edit buffer for the src block
--                           containing `line` (defaults to current).
--   M.commit(edit_bufnr)    write back & close.  Bound automatically
--                           to `:write` and `BufWriteCmd` on the edit
--                           buffer; users typically just `:wq`.
--   M.abort(edit_bufnr)     close without writing back.

local M = {}

local obuf = require("organ.buf")
-- Find the begin/end lines of the src block enclosing `line` (1-based).
-- Returns { begin_line, end_line, lang, base_indent } or nil.
function M.find_block(bufnr, line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if line < 1 or line > total then
    return nil
  end

  -- Walk upward to a `#+begin_src LANG`.
  local begin_line, lang, indent
  for i = line, 1, -1 do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if txt:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") and i ~= line then
      return nil -- crossed an end without matching begin first
    end
    local ind, l = txt:match("^(%s*)#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+([%w_+%-]+)")
    if ind ~= nil then
      begin_line = i
      lang = l
      indent = ind
      break
    end
  end
  if not begin_line then
    return nil
  end

  -- Walk downward to the matching `#+end_src`.
  local end_line
  for i = begin_line + 1, total do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if txt:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]%s*$") then
      end_line = i
      break
    end
  end
  if not end_line then
    return nil
  end

  return {
    begin_line = begin_line,
    end_line = end_line,
    lang = lang,
    base_indent = indent,
  }
end

-- Common alias map (kept in sync with `lua/organ/treesitter_directives.lua`).
local LANG_ALIASES = {
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  js = "javascript",
  ts = "typescript",
  py = "python",
  rb = "ruby",
  rs = "rust",
  ["c++"] = "cpp",
  cxx = "cpp",
  yml = "yaml",
  md = "markdown",
  el = "lisp",
  ["emacs-lisp"] = "lisp",
}
local function resolve_filetype(lang)
  if not lang then
    return nil
  end
  lang = lang:lower()
  return LANG_ALIASES[lang] or lang
end

-- Lift the indented body lines back to column-0 source so the language
-- buffer doesn't have leading whitespace from the org file's structure.
local function strip_indent(lines, indent_str)
  if not indent_str or indent_str == "" then
    return lines
  end
  local n = #indent_str
  local out = {}
  for i, l in ipairs(lines) do
    if l:sub(1, n) == indent_str then
      out[i] = l:sub(n + 1)
    else
      -- Leave non-conforming lines as-is (e.g. blank or shorter indent).
      out[i] = l
    end
  end
  return out
end

local function add_indent(lines, indent_str)
  if not indent_str or indent_str == "" then
    return lines
  end
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = (l == "") and "" or (indent_str .. l)
  end
  return out
end

-- Per-edit-buffer state, keyed by edit-buffer ID.
M._state = {}

-- Anchors for the block's delimiter lines.  Emacs keeps markers into the
-- source buffer (`org-src.el`); extmarks are the Neovim equivalent, and
-- without them a commit writes to line numbers that any edit above the
-- block has already invalidated.
local NS = vim.api.nvim_create_namespace("organ_edit_special")
M._ns = NS

local BEGIN_PAT = "^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]"
local END_PAT = "^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]%s*$"

local function drop_anchors(s)
  if not s or not vim.api.nvim_buf_is_valid(s.source) then
    return
  end
  for _, id in ipairs({ s.begin_mark, s.end_mark }) do
    if id then
      pcall(vim.api.nvim_buf_del_extmark, s.source, NS, id)
    end
  end
end

-- Current 1-based delimiter lines of the anchored block, or nil when the
-- anchors no longer straddle a `#+begin_src` / `#+end_src` pair.
local function resolve_block(s)
  local function row_of(id)
    local pos = id and vim.api.nvim_buf_get_extmark_by_id(s.source, NS, id, {})
    return pos and pos[1]
  end
  local brow, erow = row_of(s.begin_mark), row_of(s.end_mark)
  if not brow or not erow or erow <= brow then
    return nil
  end
  local total = vim.api.nvim_buf_line_count(s.source)
  if brow >= total or erow >= total then
    return nil
  end
  local btxt = vim.api.nvim_buf_get_lines(s.source, brow, brow + 1, false)[1] or ""
  local etxt = vim.api.nvim_buf_get_lines(s.source, erow, erow + 1, false)[1] or ""
  if not btxt:match(BEGIN_PAT) or not etxt:match(END_PAT) then
    return nil
  end
  return brow + 1, erow + 1
end

-- Open the source-edit buffer in a horizontal split below.
function M.open(bufnr, line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  line = line or vim.fn.line(".")

  local block = M.find_block(bufnr, line)
  if not block then
    require("organ.notify").warn("not inside a #+begin_src block")
    return nil
  end

  local body_first = block.begin_line + 1
  local body_last = block.end_line - 1
  local body
  if body_first > body_last then
    body = {}
  else
    body = vim.api.nvim_buf_get_lines(bufnr, body_first - 1, body_last, false)
    body = strip_indent(body, block.base_indent)
  end

  local source_path = vim.api.nvim_buf_get_name(bufnr)
  local short = vim.fn.fnamemodify(source_path ~= "" and source_path or "[org]", ":t")
  local edit = vim.api.nvim_create_buf(false, true)
  local name = string.format(
    "organ://edit-src/%s/%d-%d/%s",
    short,
    block.begin_line,
    block.end_line,
    block.lang or "src"
  )
  pcall(vim.api.nvim_buf_set_name, edit, name)

  local ft = resolve_filetype(block.lang)
  if ft and ft ~= "" then
    vim.api.nvim_set_option_value("filetype", ft, { buf = edit })
  end
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = edit })
  obuf.set_lines(edit, 0, -1, body)
  vim.api.nvim_set_option_value("modified", false, { buf = edit })

  M._state[edit] = {
    source = bufnr,
    begin_mark = vim.api.nvim_buf_set_extmark(bufnr, NS, block.begin_line - 1, 0, {}),
    end_mark = vim.api.nvim_buf_set_extmark(bufnr, NS, block.end_line - 1, 0, {}),
    base_indent = block.base_indent,
    lang = block.lang,
    empty = #body == 0,
  }

  -- Open in a split.
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, edit)

  -- Winbar: language + source line range + write/quit hint.
  pcall(function()
    require("organ.ui").set_winbar(vim.api.nvim_get_current_win(), {
      { ":w", "save back to org" },
      { ":q", "close (discard if unsaved)" },
    }, {
      title = string.format(
        "edit-src %s · lines %d-%d",
        block.lang or "src",
        block.begin_line,
        block.end_line
      ),
    })
  end)

  -- BufWriteCmd: write the edit buffer's contents back to the source.
  require("organ.errors").autocmd("BufWriteCmd", {
    buffer = edit,
    callback = function()
      M.commit(edit)
    end,
  })
  -- BufWipeout: clean up state.
  require("organ.errors").autocmd("BufWipeout", {
    buffer = edit,
    once = true,
    callback = function()
      drop_anchors(M._state[edit])
      M._state[edit] = nil
    end,
  })

  return edit
end

-- Write the edit buffer's contents back to the source org buffer.
function M.commit(edit_bufnr)
  edit_bufnr = edit_bufnr or vim.api.nvim_get_current_buf()
  local s = M._state[edit_bufnr]
  if not s then
    require("organ.notify").error("edit-special: no associated source")
    return false
  end
  if not vim.api.nvim_buf_is_valid(s.source) then
    require("organ.notify").error("edit-special: source buffer no longer valid")
    return false
  end
  local begin_line, end_line = resolve_block(s)
  if not begin_line then
    require("organ.notify").error("edit-special: the source block is gone; nothing written back")
    return false
  end

  local body = vim.api.nvim_buf_get_lines(edit_bufnr, 0, -1, false)
  -- An empty buffer reads back as one empty line; keep an untouched empty
  -- block empty rather than growing it by a line per round trip.
  if s.empty and #body == 1 and body[1] == "" then
    body = {}
  end
  local indented = add_indent(body, s.base_indent)
  obuf.set_lines(s.source, begin_line, end_line - 1, indented)

  vim.api.nvim_set_option_value("modified", false, { buf = edit_bufnr })
  return true
end

function M.abort(edit_bufnr)
  edit_bufnr = edit_bufnr or vim.api.nvim_get_current_buf()
  if M._state[edit_bufnr] then
    drop_anchors(M._state[edit_bufnr])
    M._state[edit_bufnr] = nil
    vim.api.nvim_set_option_value("modified", false, { buf = edit_bufnr })
    vim.api.nvim_buf_delete(edit_bufnr, { force = true })
  end
end

M.commands = {
  edit_special = {
    fn = function()
      M.open(0, vim.fn.line("."))
    end,
    desc = "Open the src block at cursor in a language buffer (Emacs C-c ')",
  },
}

return M
