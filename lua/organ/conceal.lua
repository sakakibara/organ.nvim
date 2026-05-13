-- Inline emphasis-marker + link-bracket concealment.
--
-- Walks the `org_inline` tree for the visible window range and places
-- conceal extmarks that hide the surrounding `*` `/` `_` `+` `=` `~`
-- of bold, italic, underline, strikethrough, verbatim and code spans,
-- plus the `[[target][` prefix and trailing `]]` of
-- `[[target][description]]` links.  Marks have no visual effect at
-- `conceallevel = 0` (Neovim default); the user opts in by setting
-- `conceallevel = 2` on the window or via `:Org conceal toggle`.
--
-- Concealment runs as an `organ.decoration` provider: `on_win` walks
-- the cached tree-sitter parse (refreshed once per redraw by
-- organ.decoration) and builds a module-local frame-row span map;
-- `on_line` reads from that map and emits conceal extmarks for the
-- current row.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_emphasis_conceal")

-- Tree-sitter node-type -> config-key.  Missing or `false` config keeps
-- the markup visible.
local EMPHASIS_TYPES = {
  bold = "bold",
  italic = "italic",
  underline = "underline",
  strike = "strike",
  verbatim = "verbatim",
  code = "code",
}

-- `link_regular` covers `[[target][description]]` and `[[target]]`.
-- When a description is present, hide the leading `[[target][` and the
-- trailing `]]` so only the description renders.  Bare `[[target]]`
-- stays visible (target IS the body).
local LINK_TYPES = {
  link_regular = "links",
}

-- Public list of element keys, ordered for `:Org conceal toggle <Tab>`.
M.ELEMENTS = { "bold", "italic", "underline", "strike", "verbatim", "code", "links" }

local function element_enabled(bufnr, name)
  local v = require("organ.buf_config").read(bufnr, "emphasis." .. name)
  if v == nil then
    return true
  end
  return v ~= false
end

-- Frame-local span map: frame_map[row] = { { start_col, end_col }, ... }.
-- Reset at the start of every on_win call; read by on_line for the
-- same frame.  No per-buffer keying: only one window's on_win runs
-- before its on_line callbacks for the same frame.
local frame_map = {}

-- Emit one open + (optionally) one close marker span for an emphasis
-- node.  Single-char open/close at the inclusive node range edges.
local function walk_emphasis(node, push)
  local sr, sc, er, ec = node:range()
  push(sr, sc, sc + 1)
  if er > sr or ec > sc + 1 then
    push(er, math.max(0, ec - 1), ec)
  end
end

-- Hide `[[target][` prefix and trailing `]]` of a regular link when a
-- description child is present; show bare `[[target]]` unchanged.
local function walk_link(node, push)
  local desc_node, target_node
  for c in node:iter_children() do
    local t = c:type()
    if t == "link_description" then
      desc_node = c
    elseif t == "link_target" then
      target_node = c
    end
  end
  if not desc_node then
    return
  end
  local sr, sc, er, ec = node:range()
  if target_node then
    local _, _, ter, tec = target_node:range()
    -- target_end .. target_end+2 covers `][` (single-line links).
    if ter == sr then
      push(sr, sc, tec + 2)
    end
  else
    -- Parser quirk: no target node.  Fall back to leading `[[`.
    push(sr, sc, sc + 2)
  end
  if er == sr then
    push(er, ec - 2, ec)
  end
end

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  -- Tree is parsed once per buffer per redraw by organ.decoration; ensure
  -- the cache is warm before we walk injected org_inline trees below.
  if not require("organ.decoration").get_tree(bufnr) then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return
  end

  local function push(row, start_col, end_col)
    if end_col <= start_col then
      return
    end
    -- Multi-line emphasis can produce close markers outside the frame
    -- range; skip them rather than emitting marks that can't render.
    if row < topline or row > botline then
      return
    end
    frame_map[row] = frame_map[row] or {}
    frame_map[row][#frame_map[row] + 1] = { start_col = start_col, end_col = end_col }
  end

  -- parser:children() returns a string-keyed table (lang -> child);
  -- ipairs skips it, so iterate via pairs.
  for _, child in pairs(parser:children()) do
    if child:lang() == "org_inline" then
      for _, tree in ipairs(child:trees() or {}) do
        local root = tree:root()
        local rsr, _, rer, _ = root:range()
        if rer >= topline and rsr <= botline then
          local function walk(node)
            local t = node:type()
            local emph = EMPHASIS_TYPES[t]
            if emph and element_enabled(bufnr, emph) then
              walk_emphasis(node, push)
            elseif LINK_TYPES[t] and element_enabled(bufnr, LINK_TYPES[t]) then
              walk_link(node, push)
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
end

local function on_line(bufnr, winid, row)
  if vim.wo[winid].conceallevel == 0 then
    return
  end
  local spans = frame_map[row]
  if not spans or #spans == 0 then
    return
  end
  for _, s in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, s.start_col, {
      end_col = s.end_col,
      conceal = "",
      ephemeral = true,
    })
  end
end

require("organ.decoration").register({
  name = "conceal",
  ns = NS,
  enabled = function(_bufnr)
    return true
  end,
  on_win = on_win,
  on_line = on_line,
})

-- Test-facing: drive on_win across the full buffer and place
-- non-ephemeral extmarks.  Used by `:Org conceal toggle`, by
-- `toggle_element` for an immediate visual refresh, and by tests that
-- need to assert on placed marks without a real redraw context.
local function apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  -- Place non-ephemeral marks for every populated row.  Bypasses the
  -- conceallevel check because callers (toggle, tests) want marks to
  -- be inspectable / take effect immediately.
  for row, spans in pairs(frame_map) do
    for _, s in ipairs(spans) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, s.start_col, {
        end_col = s.end_col,
        conceal = "",
      })
    end
  end
end

M._apply = apply
M._frame_map = function()
  return frame_map
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.wo.conceallevel ~= 0 then
    M.detach(bufnr)
    vim.wo.conceallevel = 0
    return false
  end
  apply(bufnr)
  vim.wo.conceallevel = 2
  return true
end

-- Flip a single element's config flag and re-apply.  Returns the new
-- state (true = concealed, false = visible).  Per-element flags live
-- on the buffer's effective config so toggles persist for the rest of
-- the session; users wanting persistent preferences set them in
-- `setup()`.  Touches every loaded org buffer so a single toggle is
-- consistent across windows.
function M.toggle_element(name)
  local buf_config = require("organ.buf_config")
  local cur = buf_config.read(0, "emphasis." .. name)
  if cur == nil then
    cur = true
  end
  local new_val = not cur
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      buf_config.set(b, "emphasis." .. name, new_val)
      apply(b)
    end
  end
  return new_val
end

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
