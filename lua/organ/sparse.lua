-- lua/organ/sparse.lua
-- Sparse tree implementation: visibility computation, foldexpr, apply/clear,
-- and predicate factories (show_todo, show_tag, show_regex).

local M = {}

-- section 3  Pure visibility computation

--- Compute which 1-based line numbers should be visible given a predicate.
---
--- Rules:
---  1. A headline whose predicate(h) is true is visible ("a match").
---  2. Every ancestor of a match is visible.
---  3. Every body line (non-headline) directly under a match is visible —
---     i.e. lines from match_line+1 up to (but not including) the next
---     headline of any level.
---
---@param buf_lines string[]  1-indexed table of buffer lines
---@param predicate function  predicate(headline) -> bool
---@param bufnr     integer?  optional; enables tree-sitter walks via element.lua
---@return table              {[lnum]=true} set of visible 1-based line numbers
function M._compute_visible(buf_lines, predicate, bufnr)
  local element = require("organ.element")
  local headlines

  if bufnr and element.parser_loaded(bufnr) then
    -- Tree-sitter path: every field already decomposed by the grammar.
    headlines = {}
    for _, h in ipairs(element.headlines(bufnr)) do
      headlines[#headlines + 1] = {
        line = h.line_start + 1, -- 1-based
        level = h.level,
        todo_state = h.todo_state,
        tags = h.tags or {},
        title = h.title,
        _node = h.node,
      }
    end
  else
    -- Regex path (parser not loaded, e.g. early boot or scratch buffer).
    headlines = {}
    for i, line in ipairs(buf_lines) do
      local stars, body = line:match("^(%*+)%s+(.*)$")
      if stars then
        local todo_state, rest
        local first_token, after = body:match("^(%S+)%s+(.*)$")
        if first_token then
          local cfg_todo = (require("organ.buf_config").read(nil, "todo") or {}).sequence
            or { "TODO", "DONE" }
          local is_todo = false
          for _, k in ipairs(cfg_todo) do
            if k ~= "|" and k == first_token then
              is_todo = true
              break
            end
          end
          if is_todo then
            todo_state = first_token
            rest = after
          else
            rest = body
          end
        else
          rest = body
        end
        local tags = {}
        for tag in (rest or ""):gmatch(":(%w+):") do
          tags[#tags + 1] = tag
        end
        local title = (rest or ""):gsub("%s+:%w[:%w]*:%s*$", "")
        headlines[#headlines + 1] = {
          line = i,
          level = #stars,
          todo_state = todo_state,
          tags = tags,
          title = title,
        }
      end
    end
  end

  -- Lazy `properties` accessor — only scans the PROPERTIES drawer when a
  -- predicate actually reads `h.properties` (the match-query path does;
  -- the simpler tag/regex predicates don't).  Uses TS field walks when
  -- the parser is loaded; regex on `buf_lines` otherwise.
  local function _scan_properties_ts(h)
    local out = {}
    if not h._node then
      return out
    end
    for child in h._node:iter_children() do
      if child:type() == "section" then
        for c in child:iter_children() do
          if c:type() == "property_drawer" then
            for np in c:iter_children() do
              if np:type() == "node_property" then
                local kn, vn
                for f in np:iter_children() do
                  local t = f:type()
                  if t == "property_name" then
                    kn = f
                  elseif t == "property_value" then
                    vn = f
                  end
                end
                if kn then
                  local sr, sc, _, ec = kn:range()
                  local k = vim.api.nvim_buf_get_text(bufnr, sr, sc, sr, ec, {})[1]
                  local v = ""
                  if vn then
                    local vr, vc, _, vec = vn:range()
                    v = vim.api.nvim_buf_get_text(bufnr, vr, vc, vr, vec, {})[1] or ""
                  end
                  if k then
                    out[k] = v
                  end
                end
              end
            end
            return out
          end
        end
        return out
      end
    end
    return out
  end
  local function _scan_properties_regex(h)
    local i = h.line + 1
    while
      i <= #buf_lines
      and (
        buf_lines[i]:match("^%s*SCHEDULED:")
        or buf_lines[i]:match("^%s*DEADLINE:")
        or buf_lines[i]:match("^%s*CLOSED:")
        or buf_lines[i]:match("^%s*$")
      )
    do
      i = i + 1
    end
    local out = {}
    if buf_lines[i] and buf_lines[i]:match("^%s*:PROPERTIES:") then
      i = i + 1
      while i <= #buf_lines and not buf_lines[i]:match("^%s*:END:") do
        local k, v = buf_lines[i]:match("^%s*:([%w_]+):%s*(.-)%s*$")
        if k then
          out[k] = v
        end
        i = i + 1
      end
    end
    return out
  end
  local scan_properties = (bufnr and element.parser_loaded(bufnr)) and _scan_properties_ts
    or _scan_properties_regex
  for _, h in ipairs(headlines) do
    setmetatable(h, {
      __index = function(t, k)
        if k == "properties" then
          local p = scan_properties(t)
          rawset(t, "properties", p)
          return p
        end
      end,
    })
  end

  -- Find matches.
  local matched = {}
  for _, h in ipairs(headlines) do
    if predicate(h) then
      matched[h.line] = h
    end
  end

  local visible = {}

  -- Mark matches and their ancestors visible.
  for hl_line, h in pairs(matched) do
    visible[hl_line] = true
    -- Walk backwards through the headlines list to find ancestors.
    -- An ancestor is the nearest preceding headline at each successive
    -- shallower level (level - 1, level - 2, …, 1).
    local needed = h.level - 1
    for i = #headlines, 1, -1 do
      local hh = headlines[i]
      if hh.line < h.line and hh.level <= needed then
        visible[hh.line] = true
        needed = hh.level - 1
        if needed == 0 then
          break
        end
      end
    end
  end

  -- Mark body lines under each match visible.
  for hl_line, _ in pairs(matched) do
    -- Find the next headline (any level) after hl_line.
    local next_hl = #buf_lines + 1
    for _, hh in ipairs(headlines) do
      if hh.line > hl_line then
        next_hl = hh.line
        break
      end
    end
    for i = hl_line + 1, next_hl - 1 do
      visible[i] = true
    end
  end

  return visible
end

-- section 4  Foldexpr

--- Foldexpr for sparse-tree mode.  Returns "0" (no fold) for visible lines
--- and "9" (deep fold) for hidden lines.
---
---@param lnum integer  1-based line number (v:lnum)
---@return string
function M.foldexpr(lnum)
  local s = vim.b.organ_sparse
  if not s or not s.visible then
    return "0"
  end
  if s.visible[lnum] then
    return "0"
  end
  return "9"
end

-- section 5  Apply / clear

--- Apply a sparse tree to a buffer: compute visibility and switch foldexpr.
---
---@param bufnr  integer    buffer number
---@param predicate function predicate(headline) -> bool
function M.apply(bufnr, predicate)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local visible = M._compute_visible(lines, predicate, bufnr)

  -- Save current foldmethod so clear() can restore it.
  local winid = vim.fn.bufwinid(bufnr)
  local saved = winid > 0 and vim.api.nvim_get_option_value("foldmethod", { win = winid })
    or "manual"

  vim.b[bufnr].organ_sparse = { visible = visible, _saved_foldmethod = saved }

  -- foldexpr/foldmethod/foldlevel are window-local.
  if winid > 0 then
    vim.api.nvim_set_option_value(
      "foldexpr",
      "v:lua.require'organ.sparse'.foldexpr(v:lnum)",
      { win = winid }
    )
    vim.api.nvim_set_option_value("foldmethod", "expr", { win = winid })
    vim.api.nvim_set_option_value("foldlevel", 0, { win = winid })
  end
end

--- Clear a sparse tree view and restore the prior foldmethod.
---
---@param bufnr integer  buffer number
function M.clear(bufnr)
  local s = vim.b[bufnr].organ_sparse
  if not s then
    return
  end
  local winid = vim.fn.bufwinid(bufnr)
  if winid > 0 then
    vim.api.nvim_set_option_value("foldmethod", s._saved_foldmethod or "manual", { win = winid })
    vim.api.nvim_set_option_value("foldlevel", 99, { win = winid }) -- open all
  end
  vim.b[bufnr].organ_sparse = nil
end

-- section 6  Predicate factories

--- Show only headlines that have a TODO state (optionally a specific state).
---
---@param bufnr  integer
---@param state? string  specific TODO keyword to match; nil = any TODO state
function M.show_todo(bufnr, state)
  M.apply(bufnr, function(h)
    if not h.todo_state then
      return false
    end
    if state then
      return h.todo_state == state
    end
    return true
  end)
end

--- Show only headlines tagged with a specific tag.
---
---@param bufnr integer
---@param tag   string
function M.show_tag(bufnr, tag)
  M.apply(bufnr, function(h)
    for _, t in ipairs(h.tags or {}) do
      if t == tag then
        return true
      end
    end
    return false
  end)
end

--- Show only headlines whose title matches a Lua pattern.
---
---@param bufnr   integer
---@param pattern string  Lua pattern matched against headline title
function M.show_regex(bufnr, pattern)
  M.apply(bufnr, function(h)
    return h.title and h.title:match(pattern) ~= nil
  end)
end

--- Show headlines matching an Emacs `org-match` query
--- (e.g. `+work-home/+NEXT|+@phone+EFFORT<60`). See lua/organ/match.lua
--- for the supported subset.
---
---@param bufnr  integer
---@param query  string
function M.show_match(bufnr, query)
  local pred = require("organ.match").predicate(query)
  M.apply(bufnr, pred)
end

M.commands = {
  ["sparse_tree todo"] = {
    fn = function(cmd)
      local state = cmd.args ~= "" and cmd.args or nil
      M.show_todo(0, state)
    end,
    nargs = "?",
    desc = "Sparse tree: only TODO-state headlines",
  },
  ["sparse_tree tag"] = {
    fn = function(cmd)
      if cmd.args == "" then
        require("organ.notify").warn("tag required")
        return
      end
      M.show_tag(0, cmd.args)
    end,
    nargs = 1,
    desc = "Sparse tree: only headlines with this tag",
  },
  ["sparse_tree regex"] = {
    fn = function(cmd)
      if cmd.args == "" then
        require("organ.notify").warn("regex required")
        return
      end
      M.show_regex(0, cmd.args)
    end,
    nargs = 1,
    desc = "Sparse tree: headlines whose title matches this regex",
  },
  ["sparse_tree clear"] = {
    fn = function()
      M.clear(0)
    end,
    desc = "Clear sparse tree view",
  },
  ["sparse_tree match"] = {
    fn = function(cmd)
      local query = cmd and cmd.args or ""
      if query == "" then
        require("organ.notify").warn(":Org sparse_tree match needs a query (e.g. +work-home)")
        return
      end
      local ok, err = pcall(M.show_match, 0, query)
      if not ok then
        require("organ.notify").error(tostring(err))
      end
    end,
    nargs = 1,
    desc = "Sparse tree from Emacs org-match query",
  },
}

return M
