-- Custom tree-sitter query directives for organ.
--
-- Registers two directives that injections.scm uses:
--
--   #org-src-block-lang!  — given a captured src_block node, set the
--                           injection language to the value after
--                           `#+begin_src` on the first line, lower-cased.
--                           Aliases common languages (e.g. "shell" → "bash").
--
--   #org-src-block-body!  — given a captured src_block node, set the
--                           injection content range to the body bytes only
--                           (excluding the `#+begin_src …` and `#+end_src`
--                           lines), so the embedded language parser sees
--                           clean source.

local M = {}

-- Aliases for common language names that don't map 1:1 to tree-sitter parser
-- names.  Extend freely; keys are lower-cased begin_src arguments, values are
-- the parser name to inject.
local LANG_ALIASES = {
  ["sh"] = "bash",
  ["shell"] = "bash",
  ["zsh"] = "bash",
  ["js"] = "javascript",
  ["ts"] = "typescript",
  ["py"] = "python",
  ["rb"] = "ruby",
  ["rs"] = "rust",
  ["c++"] = "cpp",
  ["cxx"] = "cpp",
  ["objc"] = "objc",
  ["yml"] = "yaml",
  ["md"] = "markdown",
  ["el"] = "elisp",
  ["emacs-lisp"] = "elisp",
  ["restclient"] = "http",
  ["ipython"] = "python",
  ["jupyter"] = "python",
  ["plantuml"] = "plantuml",
  ["dot"] = "dot",
  ["graphviz"] = "dot",
}

-- Resolve a begin_src argument to a parser language name.
local function resolve_lang(arg)
  if not arg or arg == "" then
    return nil
  end
  arg = arg:lower()
  return LANG_ALIASES[arg] or arg
end

-- Pull the begin-line language out of a src_block node.
-- Returns the resolved parser name, or nil if not extractable.
local function src_block_lang(node, source)
  -- get_node_text can throw with "Index out of bounds" when the highlighter
  -- runs against a stale tree (e.g. mid-undo, before the next reparse).
  -- Treat any throw as "no extractable text" so the predicate / range
  -- directive falls through to its default no-match path.
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  if not ok or not text then
    return nil
  end
  local first = text:match("^[^\n]*") or ""
  local lang = first:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+([%w_+%-]+)")
  return resolve_lang(lang)
end

-- Body byte range of a src_block: from end of begin line through start of
-- end line.  Returns start_row, start_col, end_row, end_col, start_byte,
-- end_byte — the range tuple tree-sitter injection metadata expects.
local function src_block_body_range(node, source)
  local sr, sc, er, ec, sb, eb = node:range(true)
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  if not ok or not text then
    return nil
  end

  local first_nl = text:find("\n", 1, true)
  if not first_nl then
    return nil
  end
  local body_start_byte = sb + first_nl -- byte AFTER the first newline

  -- Find start of last line (the `#+end_src` line).
  local last_nl
  do
    local i = #text
    while i > 0 do
      if text:sub(i, i) == "\n" then
        last_nl = i
        break
      end
      i = i - 1
    end
  end
  if not last_nl then
    return nil
  end
  -- The end_* line might or might not be terminated by a newline; treat the
  -- second-to-last newline as the body end.
  local prev_nl = text:sub(1, last_nl - 1):find("\n[^\n]*$")
  local body_end_byte = sb + (prev_nl or last_nl) - 1

  if body_end_byte <= body_start_byte then
    return nil
  end

  -- Convert to row/col by walking the source.  We only need the bytes for
  -- injection.combined: pass byte-only via metadata.range.
  return body_start_byte, body_end_byte
end

-- Count leading `*` characters of a headline node's first line.
local function headline_stars(node, source)
  local sr, sc = node:start()
  -- Quick path: pull the first line directly.
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  if not ok or not text then
    return 0
  end
  local first = text:match("^[^\n]*") or ""
  local stars = first:match("^(%*+)%s") or ""
  return #stars
end

-- Reach into the user's todo sequence (split into active vs done
-- sets).  When `source` is a buffer number (or string with `\n`-
-- separated lines), scan it for `#+TODO:` directives and merge any
-- buffer-local keywords on top of the global sequence so files that
-- introduce their own states (`WAIT`, `SOMEDAY`, etc.) get their
-- keywords highlighted as TODO without a config restart.
local function todo_sets(source)
  local active, done = {}, {}
  local ok, organ = pcall(require, "organ")
  if ok and organ.config and require("organ.buf_config").read(nil, "todo") then
    local raw = require("organ.buf_config").read(nil, "todo.sequences")
      or require("organ.buf_config").read(nil, "todo.sequence")
      or {}
    local sequences = require("organ.todo")._normalise_sequences(raw)
    for _, seq in ipairs(sequences) do
      local in_done = false
      for _, k in ipairs(seq) do
        if k == "|" then
          in_done = true
        elseif in_done then
          done[k] = true
        else
          active[k] = true
        end
      end
    end
  end
  if next(active) == nil and next(done) == nil then
    active, done = { TODO = true }, { DONE = true }
  end
  -- Buffer-local `#+TODO:` directives.  Mirror Emacs's `org-todo-
  -- keywords` per-file syntax: `#+TODO: TODO NEXT | DONE`.  Multiple
  -- lines accumulate.  Keywords with action shortcuts (`WAIT(w@/!)`)
  -- have the parens stripped before adding to the set.
  local lines
  if type(source) == "number" and vim.api.nvim_buf_is_valid(source) then
    -- Scan the first 200 lines (directives sit near the top).
    local n = math.min(200, vim.api.nvim_buf_line_count(source))
    lines = vim.api.nvim_buf_get_lines(source, 0, n, false)
  elseif type(source) == "string" then
    lines = {}
    for l in (source .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = l
      if #lines >= 200 then
        break
      end
    end
  end
  if lines then
    for _, l in ipairs(lines) do
      local val = l:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.*)$")
      if val then
        local seen_pipe = false
        for tok in val:gmatch("%S+") do
          if tok == "|" then
            seen_pipe = true
          else
            -- strip the (key/action) suffix
            local kw = tok:match("^([%w_%-]+)") or tok
            if kw ~= "" then
              if seen_pipe then
                done[kw] = true
              else
                active[kw] = true
              end
            end
          end
        end
      end
    end
  end
  return active, done
end

-- Register directives with the tree-sitter query engine.  Idempotent:
-- repeated calls (e.g. plugin/organ.lua + a test bootstrap) reuse the
-- existing registrations without throwing "Overriding existing
-- predicate".  Tracks via a module-local flag rather than the engine's
-- internal state because nvim's add_predicate has no force-replace
-- option for our cross-version target.
function M.register()
  if M._registered then
    return
  end
  M._registered = true
  local q = vim.treesitter.query

  -- Per-level (stars) predicate. Usage in highlights.scm:
  --   ((headline_line stars: (stars) @org.heading.1)
  --    (#org-stars-level? @org.heading.1 1))
  -- Counts the `*` chars in the captured node's text and compares to
  -- the requested level. Used by the modern field-based heading
  -- highlight rules that capture `(stars)` directly.
  q.add_predicate("org-stars-level?", function(match, _, source, predicate)
    local capture_id = predicate[2]
    local want_level = tonumber(predicate[3])
    if not want_level then
      return false
    end
    local nodes = match[capture_id]
    if not nodes then
      return false
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return false
    end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    return #text == want_level
  end, { all = false })

  -- TODO-keyword classifier on a captured `(todo)` node.
  -- Usage:
  --   (headline_line todo: (todo) @org.todo.active
  --     (#org-todo-keyword? @org.todo.active active))
  -- Tests the captured node's text against `config.todo.sequence`,
  -- splitting on `|` to distinguish active / done.
  q.add_predicate("org-todo-keyword?", function(match, _, source, predicate)
    local capture_id = predicate[2]
    local kind = predicate[3]
    local nodes = match[capture_id]
    if not nodes then
      return false
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return false
    end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    local kw = text:gsub("%s+", "")
    local active, done = todo_sets(source)
    if kind == "active" then
      return active[kw] == true
    end
    if kind == "done" then
      return done[kw] == true
    end
    return active[kw] == true or done[kw] == true
  end, { all = false })

  -- Per-level headline predicate. Usage in highlights.scm:
  --   ((headline) @org.heading.1 (#org-heading-level? @org.heading.1 1))
  --   ((headline) @org.heading.2 (#org-heading-level? @org.heading.2 2))
  --   ...
  q.add_predicate("org-heading-level?", function(match, _, source, predicate)
    local capture_id = predicate[2]
    local want_level = tonumber(predicate[3])
    if not want_level then
      return false
    end
    local nodes = match[capture_id]
    if not nodes then
      return false
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return false
    end
    return headline_stars(node, source) == want_level
  end, { all = false })

  -- Predicate: true iff the headline's first non-stars token is a TODO
  -- keyword in the requested set ("active" / "done"). Pair with the
  -- range directive so non-matches don't render the whole headline.
  q.add_predicate("org-has-todo-kw?", function(match, _, source, predicate)
    local capture_id = predicate[2]
    local kind = predicate[3]
    local nodes = match[capture_id]
    if not nodes then
      return false
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return false
    end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    local first = text:match("^[^\n]*") or ""
    local _, _, kw = first:find("^%*+%s+(%S+)")
    if not kw then
      return false
    end
    local active, done = todo_sets(source)
    if kind == "active" then
      return active[kw] == true
    end
    if kind == "done" then
      return done[kw] == true
    end
    return active[kw] == true or done[kw] == true
  end, { all = false })

  -- Predicate: true iff the headline carries a [#A] / [#B] / [#C] cookie.
  q.add_predicate("org-has-priority?", function(match, _, source, predicate)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes then
      return false
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return false
    end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    local first = text:match("^[^\n]*") or ""
    return first:find("%[#%w%]") ~= nil
  end, { all = false })

  -- Predicate: true iff the headline ends in a `:tag1:tag2:` block.
  q.add_predicate("org-has-tags?", function(match, _, source, predicate)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes then
      return false
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return false
    end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    local first = text:match("^[^\n]*") or ""
    return first:find("%s+:[%w_@#%%]+:%s*$") ~= nil
  end, { all = false })

  -- Range directive: when the captured node is a headline whose first word
  -- after the stars is a configured TODO keyword, narrow the capture to
  -- ONLY that keyword's byte range. Argument selects "active" or "done".
  -- Usage in highlights.scm:
  --   ((headline) @org.todo.active (#org-has-todo-kw? @org.todo.active active)
  --                                (#org-todo-keyword! @org.todo.active active))
  q.add_directive("org-todo-keyword!", function(match, _, source, predicate, metadata)
    local capture_id = predicate[2]
    local kind = predicate[3]
    local nodes = match[capture_id]
    if not nodes then
      return
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return
    end
    local sr, sc = node:start()
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    if not text then
      return
    end
    local first = text:match("^[^\n]*") or ""
    local stars, kw_start_off, kw, kw_end_off = first:find("^(%*+)%s+(%S+)()")
    -- Pattern groups: stars (1), kw (2). `()` captures positions.
    if not stars then
      return
    end
    local kw_start, kw_end = first:find("^%*+%s+(%S+)")
    -- The above isn't ideal; use a cleaner re-extract:
    local s_idx, e_idx, captured = first:find("^%*+%s+(%S+)")
    if not captured then
      return
    end
    local kw_text = captured
    local active, done = todo_sets(source)
    local in_set = (kind == "active") and active or done
    if not in_set[kw_text] then
      return
    end
    -- Compute byte offsets of the keyword within `first`.
    local kw_byte_start = first:find(vim.pesc(kw_text), 1, false) - 1 -- 0-based col
    local kw_byte_end = kw_byte_start + #kw_text
    metadata[capture_id] = metadata[capture_id] or {}
    metadata[capture_id].range = {
      sr,
      sc + kw_byte_start,
      sr,
      sc + kw_byte_end,
    }
  end, { all = true })

  -- Narrow a (headline) capture to JUST its first line (the heading line
  -- itself), so highlights on @org.heading.N don't bleed onto the body
  -- content under the heading. tree-sitter-organ's `(headline)` node spans
  -- the whole subtree (heading + body + nested headlines); without this
  -- directive, @org.heading.1 paints the entire file under a level-1
  -- heading, @org.heading.2 paints sub-trees, and the actual heading lines
  -- never visually stand out.
  q.add_directive("org-heading-line!", function(match, _, source, predicate, metadata)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes then
      return
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return
    end
    local sr, sc = node:start()
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    if not text then
      return
    end
    local first_line = text:match("^[^\n]*") or ""
    metadata[capture_id] = metadata[capture_id] or {}
    metadata[capture_id].range = { sr, sc, sr, sc + #first_line }
  end, { all = true })

  -- Same idea for priority cookies `[#A]` / `[#B]` / `[#C]`.
  q.add_directive("org-priority!", function(match, _, source, predicate, metadata)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes then
      return
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return
    end
    local sr, sc = node:start()
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    if not text then
      return
    end
    local first = text:match("^[^\n]*") or ""
    local s, e = first:find("%[#%w%]")
    if not s then
      return
    end
    metadata[capture_id] = metadata[capture_id] or {}
    metadata[capture_id].range = { sr, sc + s - 1, sr, sc + e }
  end, { all = true })

  -- Trailing tag block `:tag1:tag2:` at the end of a headline.
  q.add_directive("org-tags!", function(match, _, source, predicate, metadata)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes then
      return
    end
    local node = type(nodes) == "table" and nodes[1] or nodes
    if not node then
      return
    end
    local sr, sc = node:start()
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if not ok or not text then
      return false
    end
    if not text then
      return
    end
    local first = text:match("^[^\n]*") or ""
    local s, e = first:find("%s+(:[%w_@#%%]+:)%s*$")
    if not s then
      return
    end
    -- s is the start of the leading whitespace; we want the colon position.
    local _, tag_s = first:find("%s+", s)
    if not tag_s then
      return
    end
    metadata[capture_id] = metadata[capture_id] or {}
    metadata[capture_id].range = { sr, sc + tag_s, sr, sc + e }
  end, { all = true })

  q.add_directive("org-src-block-lang!", function(match, _, source, predicate, metadata)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes or #nodes == 0 then
      return
    end
    local lang = src_block_lang(nodes[1], source)
    if not lang then
      return
    end
    metadata.injection = metadata.injection or {}
    metadata.injection.language = lang
  end, { all = true })

  q.add_directive("org-src-block-body!", function(match, _, source, predicate, metadata)
    local capture_id = predicate[2]
    local nodes = match[capture_id]
    if not nodes or #nodes == 0 then
      return
    end
    local sb, eb = src_block_body_range(nodes[1], source)
    if not sb then
      return
    end
    metadata[capture_id] = metadata[capture_id] or {}
    -- Tree-sitter accepts a `range` table of {start_row, start_col, end_row, end_col}
    -- via metadata.<capture>.range; we only have bytes, so compute rows by walking.
    local function pos(byte)
      local row = 0
      local col = 0
      local i = 0
      while i < byte and i < #source do
        i = i + 1
        if source:byte(i) == 10 then -- '\n'
          row = row + 1
          col = 0
        else
          col = col + 1
        end
      end
      return row, col
    end
    local sr, sc = pos(sb)
    local er, ec = pos(eb)
    metadata[capture_id].range = { sr, sc, er, ec }
  end, { all = true })
end

return M
