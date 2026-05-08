-- Inline emphasis-marker concealment.
--
-- Walks the org_inline tree per buffer change and adds extmarks that hide
-- the surrounding `*` `/` `_` `+` `=` `~` of bold / italic / underline /
-- strikethrough / verbatim / code regions when conceallevel is ≥ 2. The
-- styled body text remains visible (with its own highlight).
--
-- Concealment is a buffer-attached service: M.attach(bufnr) installs an
-- autocmd that reapplies marks on TextChanged + TextChangedI. Idempotent.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_emphasis_conceal")

-- Tree-sitter node-type → config-key mapping.  Apply() looks up the
-- config flag for each node it walks; missing or `false` means the
-- markup stays visible.
local EMPHASIS_TYPES = {
  bold = "bold",
  italic = "italic",
  underline = "underline",
  strike = "strike",
  verbatim = "verbatim",
  code = "code",
}

-- Conceal `[[target][description]]` → `description`, and
-- `[[target]]` (no description) → keep the target visible (no
-- conceal).  Mirrors Emacs `org-link-descriptive` (default true).
-- The conceal walker hides the leading `[[`, the `target][`
-- separator, and the trailing `]]` when a description is present.
local LINK_TYPES = {
  link_regular = "links",
}

-- Public list of element keys, ordered for `:Org conceal toggle <Tab>`.
M.ELEMENTS = { "bold", "italic", "underline", "strike", "verbatim", "code", "links" }

local function element_enabled(name)
  local cfg = (require("organ").config.emphasis or {})
  -- Default true if the key is missing -- mirrors Emacs "hide markers".
  local v = cfg[name]
  if v == nil then
    return true
  end
  return v ~= false
end

local function clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

-- Place a 1-char conceal extmark at (row, col) (0-based).
local function conceal_one(bufnr, row, col)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, col, {
    end_col = col + 1,
    conceal = "",
  })
end

-- Place a multi-byte conceal extmark covering [start_col, end_col)
-- on a single row.  Used for link bracket runs (`[[`, `][`, `]]`).
local function conceal_range(bufnr, row, start_col, end_col)
  if end_col <= start_col then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, start_col, {
    end_col = end_col,
    conceal = "",
  })
end

-- Conceal the `[[`, `][`, `]]` bytes of a `[[target][description]]`
-- link so the rendered result reads as just `description`.  When the
-- link has no description, leave it untouched (target IS the body).
local function conceal_link_regular(bufnr, node)
  local desc_node
  for c in node:iter_children() do
    if c:type() == "link_description" then
      desc_node = c
      break
    end
  end
  if not desc_node then
    return
  end -- bare [[target]] — show as-is
  local sr, sc = node:range()
  -- Conceal the entire `[[target][` prefix as one range so only the
  -- description (`organ.nvim`) is visible.  Concealing `[[` + target
  -- + `][` separately leaves the target text rendered between the
  -- two hidden bracket runs (visible: `id:organ-nvimorgan.nvim`).
  local target_node
  for c in node:iter_children() do
    if c:type() == "link_target" then
      target_node = c
      break
    end
  end
  if target_node then
    local _, _, ter, tec = target_node:range()
    -- target_end .. target_end+2 covers `][` (single-line links).
    if ter == sr then
      conceal_range(bufnr, sr, sc, tec + 2)
    end
  else
    -- No target node (parser quirk): fall back to just the leading `[[`.
    conceal_range(bufnr, sr, sc, sc + 2)
  end
  -- Trailing `]]` (2 bytes before node end).
  local _, _, er, ec = node:range()
  if er == sr then
    conceal_range(bufnr, er, ec - 2, ec)
  end
end

local function apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  clear(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return
  end
  -- Force inline parsing.
  pcall(function()
    parser:parse(true)
  end)

  -- parser:children() returns a string-keyed table (lang → child); ipairs
  -- sees nothing, so iterate via pairs.
  for _, child in pairs(parser:children()) do
    if child:lang() == "org_inline" then
      for _, tree in ipairs(child:trees() or {}) do
        local root = tree:root()
        local function walk(node)
          local t = node:type()
          local emph = EMPHASIS_TYPES[t]
          if emph and element_enabled(emph) then
            local sr, sc, er, ec = node:range()
            -- One char open + one char close. For verbatim/code those are
            -- `=`/`~`; for bold/italic/etc. they're `*`/`/`/`_`/`+`. All
            -- are single bytes, so col arithmetic is safe.
            conceal_one(bufnr, sr, sc)
            if er > sr or ec > sc + 1 then
              conceal_one(bufnr, er, math.max(0, ec - 1))
            end
          elseif LINK_TYPES[t] and element_enabled(LINK_TYPES[t]) then
            conceal_link_regular(bufnr, node)
          end
          for c in node:iter_children() do
            walk(c)
          end
        end
        walk(root)
      end
    end
  end
end

-- Public: attach buffer-wide concealment. Re-applies on text changes
-- (cheap because we re-walk the tree, not the buffer). Caller decides
-- conceallevel via a window option; default Neovim conceallevel = 0
-- means marks have no visual effect, so attach is harmless without it.
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  apply(bufnr)
  local group = vim.api.nvim_create_augroup("organ_conceal_" .. bufnr, { clear = true })
  local trigger = require("organ.debounce").trailing(150, function(b)
    if vim.api.nvim_buf_is_valid(b) then
      apply(b)
    end
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      trigger(bufnr)
    end,
  })
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  clear(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_conceal_" .. bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { limit = 1 })
  if #marks > 0 then
    M.detach(bufnr)
    vim.wo.conceallevel = 0
    return false
  end
  M.attach(bufnr)
  if vim.wo.conceallevel == 0 then
    vim.wo.conceallevel = 2
  end
  return true
end

-- Flip a single element's config flag and re-apply.  Returns the
-- new state (true = concealed, false = visible).  Per-element flag
-- lives on the in-process config (`require("organ").config.emphasis`)
-- so toggles persist for the rest of the session; users wanting
-- persistent preferences set them in `setup()`.
function M.toggle_element(name)
  local cfg = require("organ").config
  cfg.emphasis = cfg.emphasis or {}
  local cur = cfg.emphasis[name]
  if cur == nil then
    cur = true
  end
  cfg.emphasis[name] = not cur
  -- Re-walk every loaded org buffer so the change is reflected
  -- immediately, not on the next TextChanged.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      apply(b)
    end
  end
  return cfg.emphasis[name]
end

M._apply = apply

M.commands = {
  ["conceal toggle"] = {
    fn = function(opts)
      local arg = opts and opts.args or ""
      if arg == nil or arg == "" then
        local on = M.toggle(0)
        require("organ.notify").info("organ: emphasis conceal " .. (on and "ON" or "OFF"))
        return
      end
      if not vim.tbl_contains(M.ELEMENTS, arg) then
        require("organ.notify").warn(
          "organ: unknown element `" .. arg .. "`; valid: " .. table.concat(M.ELEMENTS, " ")
        )
        return
      end
      local on = M.toggle_element(arg)
      require("organ.notify").info("organ: conceal " .. arg .. " = " .. (on and "ON" or "OFF"))
    end,
    nargs = "?",
    complete = function()
      return M.ELEMENTS
    end,
    desc = "Toggle conceal: master (no arg) or one element (bold / italic / ... / links)",
  },
}

return M
