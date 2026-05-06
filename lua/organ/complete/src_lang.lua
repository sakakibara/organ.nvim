-- Language completion after `#+begin_src `.

local M = {}

local LANGUAGES = {
  "awk",
  "bash",
  "c",
  "clojure",
  "cpp",
  "css",
  "dockerfile",
  "dot",
  "elisp",
  "elixir",
  "fortran",
  "gnuplot",
  "go",
  "haskell",
  "html",
  "java",
  "javascript",
  "json",
  "julia",
  "kotlin",
  "latex",
  "lua",
  "make",
  "markdown",
  "ocaml",
  "perl",
  "php",
  "plantuml",
  "python",
  "r",
  "ruby",
  "rust",
  "scala",
  "scheme",
  "sh",
  "sql",
  "swift",
  "toml",
  "typescript",
  "vim",
  "yaml",
  "zsh",
}

function M.cursor_partial(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if row == nil or col == nil then
    local pos = vim.api.nvim_win_get_cursor(0)
    row = row or pos[1]
    col = col or pos[2]
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)
  return before:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \t]+([%w_+#%-]*)$")
end

function M.completion_items(partial)
  local q = (partial or ""):lower()
  local items = {}
  for _, lang in ipairs(LANGUAGES) do
    if q == "" or lang:find(q, 1, true) == 1 then
      items[#items + 1] = {
        label = lang,
        insertText = lang,
        filterText = lang,
        detail = "src block language",
      }
    end
  end
  return items
end

return M
