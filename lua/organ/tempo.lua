-- Org-tempo: type `<KEY` at the start of a line, press <Tab>, get the
-- corresponding block expansion. Mirrors Emacs `org-tempo-keywords-alist`
-- + `org-structure-template-alist`.
--
-- Default expansions (all with cursor placed inside the body region):
--   <s   →  #+begin_src   / #+end_src    (prompts language → defaults to "")
--   <e   →  #+begin_example / #+end_example
--   <q   →  #+begin_quote / #+end_quote
--   <v   →  #+begin_verse / #+end_verse
--   <c   →  #+begin_comment / #+end_comment
--   <l   →  #+begin_export latex / #+end_export
--   <h   →  #+begin_export html  / #+end_export
--   <a   →  #+begin_export ascii / #+end_export
--   <I   →  #+include: ""           (prompts inline)
--   <T   →  #+title:                (prompts inline)
--
-- Users can extend or override via config.tempo.expansions:
--   tempo = { expansions = { foo = { "#+begin_foo", "", "#+end_foo" } } }

local M = {}

local DEFAULTS = {
  s = function(lang)
    return { "#+begin_src " .. (lang or ""), "", "#+end_src" }
  end,
  e = function()
    return { "#+begin_example", "", "#+end_example" }
  end,
  q = function()
    return { "#+begin_quote", "", "#+end_quote" }
  end,
  v = function()
    return { "#+begin_verse", "", "#+end_verse" }
  end,
  c = function()
    return { "#+begin_comment", "", "#+end_comment" }
  end,
  l = function()
    return { "#+begin_export latex", "", "#+end_export" }
  end,
  h = function()
    return { "#+begin_export html", "", "#+end_export" }
  end,
  a = function()
    return { "#+begin_export ascii", "", "#+end_export" }
  end,
}

local function get_cfg()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return organ.config.tempo or {}
end

-- Resolve an expansion table for `key`. Returns a function(lang_arg)->lines
-- or nil when no match.
function M.resolve(key)
  local cfg = get_cfg()
  if cfg.expansions and cfg.expansions[key] then
    local exp = cfg.expansions[key]
    if type(exp) == "function" then
      return exp
    end
    return function()
      return exp
    end
  end
  return DEFAULTS[key]
end

-- Pure helper: given a single line + the cursor's byte column (0-based,
-- past-the-end semantics — Neovim's nvim_win_get_cursor convention), decide
-- whether the cursor sits right after a `<KEY` trigger. Returns key or nil.
function M.detect_trigger(line, col)
  line = line or ""
  col = col or #line
  local prefix = line:sub(1, col)
  local rest = line:sub(col + 1):gsub("%s+$", "")
  if rest ~= "" then
    return nil
  end
  return prefix:match("^%s*<(%w)$")
end

-- Inspect the current line for a `<KEY` trigger. Returns key (string) when
-- the cursor sits immediately after the trigger, else nil.
function M.trigger_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return M.detect_trigger(line, col)
end

-- Replace the `<KEY` trigger with the expansion. Cursor lands inside the
-- empty body line. Returns true if expansion happened.
function M.expand(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local key = M.trigger_at_cursor(bufnr)
  if not key then
    return false
  end
  local fn = M.resolve(key)
  if not fn then
    return false
  end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local lines = fn()
  if not lines or #lines == 0 then
    return false
  end
  -- Replace the line containing the trigger.
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, lines)
  -- Land cursor inside the body line (line index 1 in the inserted block).
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 2, 0 })
  return true
end

return M
