-- Org-mode formatter: paragraph rewrap that preserves headlines,
-- list bullets, drawers, blocks, planning lines, and tables.
--
-- Entry points:
--   * M.format_lines(lines, width) — pure: in-lines → out-lines.
--                                    The core algorithm; everything
--                                    else wraps this.
--   * M.formatexpr()              — vim formatexpr (`gq`).  Reads
--                                    v:lnum + v:count from the
--                                    formatexpr context.
--   * M.format_buffer(buf)        — format the entire buffer in
--                                    place.  Wired into `:Org format`
--                                    and the LSP formatting handler.
--   * M.format_range(buf, lo, hi) — format a 1-based inclusive line
--                                    range in place.
--
-- Mirrors Emacs's `org-fill-paragraph` semantics:
--   * Headlines are NEVER wrapped (they stay one line).
--   * List items wrap continuation lines under the bullet's column.
--   * Drawer / block / planning / table lines are LEFT UNCHANGED.
--   * Plain prose paragraphs wrap to `textwidth` (or 80 if unset).
--
-- Auto-format-on-save is intentionally NOT provided — that's the
-- job of conform.nvim / none-ls / the LSP `vim.lsp.buf.format`
-- BufWritePre wiring, all of which can drive this formatter.  See
-- the README "Formatting" section for recipes.

local M = {}

local function textwidth(bufnr)
  local tw = vim.bo[bufnr].textwidth
  if tw and tw > 0 then
    return tw
  end
  return 80
end

local function is_headline(line)
  return line:match("^%*+%s") ~= nil
end
local function is_planning(line)
  return line:match("^%s*[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:") ~= nil
    or line:match("^%s*[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:") ~= nil
    or line:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:") ~= nil
end
local function is_drawer_open(line)
  return line:match("^%s*:[%w_-]+:%s*$") ~= nil
end
local function is_drawer_close(line)
  return line:match("^%s*:[Ee][Nn][Dd]:%s*$") ~= nil
end
local function is_block_open(line)
  return line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") ~= nil
end
local function is_block_close(line)
  return line:match("^%s*#%+[Ee][Nn][Dd]_") ~= nil
end
local function is_directive(line)
  return line:match("^%s*#%+") ~= nil
end
local function is_table(line)
  return line:match("^%s*|") ~= nil
end
local function is_list(line)
  -- - / + / * for unordered, 1. / 1) for ordered.
  return line:match("^(%s*)[%-%+%*]%s") ~= nil or line:match("^(%s*)%d+[%.%)]%s") ~= nil
end
local function leading_indent(line)
  return line:match("^(%s*)") or ""
end

-- Pull the trailing `:tag1:tag2:` block off a headline title.  Tags
-- are valid only when (a) they sit at end-of-line (after optional
-- trailing whitespace) and (b) the segment before them ends with at
-- least one whitespace char (Emacs's `org-tag-line-re`).  Returns
-- `(title_without_tags, tag_string_or_nil)`.
local function split_trailing_tags(s)
  local body, tags = s:match("^(.-)%s+(:[%w_@#%%][%w_@#%%:]*:)%s*$")
  if body and tags then
    return body, tags
  end
  return s, nil
end

-- Normalise a headline line.  Splits into stars / todo / comment /
-- priority / title / tags, collapses internal whitespace runs, and
-- (when tags are present) right-aligns the tag block per
-- `opts.tags_column`.  Mirrors Emacs's `org-set-tags-command` align
-- pass.  Returns the rewritten line.
local function normalize_headline(line, opts)
  opts = opts or {}
  if opts.normalize_whitespace == false and not opts.tags_column then
    return line
  end
  local stars, rest = line:match("^(%*+)%s+(.-)%s*$")
  if not stars then
    return line
  end

  -- Pull tags off first; what's left is "stars-less rest" minus tags.
  local body, tags = split_trailing_tags(rest)
  body = body:gsub("%s+$", ""):gsub("^%s+", "")

  -- Optional whitespace collapse between todo / comment / priority
  -- / title fields.  Walk fields in order; the rest is the title.
  local todo_kw_set = {}
  do
    local ok, todo = pcall(require, "organ.todo")
    if ok and type(todo.all_keywords) == "function" then
      for _, k in ipairs(todo.all_keywords()) do
        todo_kw_set[k] = true
      end
    end
  end
  local pieces = {}
  local cursor = 1
  -- TODO keyword (first word, if it matches the configured set).
  do
    local first, after = body:match("^(%S+)%s+()")
    if first and todo_kw_set[first] then
      pieces[#pieces + 1] = first
      cursor = after
    end
  end
  -- COMMENT marker.
  do
    local sub = body:sub(cursor)
    local kw, after = sub:match("^(COMMENT)%s+()")
    if kw then
      pieces[#pieces + 1] = kw
      cursor = cursor + (after - 1)
    end
  end
  -- Priority cookie [#X] (X in [A-Z0-9]).  Trailing space is
  -- consumed; if absent, the cookie still parses (Emacs parity --
  -- see `priority cookie no separator` corpus test).
  do
    local sub = body:sub(cursor)
    local cookie, after = sub:match("^(%[#[%u%d]%])%s*()")
    if cookie then
      pieces[#pieces + 1] = cookie
      cursor = cursor + (after - 1)
    end
  end
  -- Everything else is the title.  Collapse internal whitespace runs.
  local title = body:sub(cursor)
  if opts.normalize_whitespace ~= false then
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
  if title ~= "" then
    pieces[#pieces + 1] = title
  end

  local left = stars
  if #pieces > 0 then
    left = stars .. " " .. table.concat(pieces, " ")
  end
  if not tags then
    return left
  end

  -- Right-align tags per opts.tags_column.
  local target = opts.tags_column
  if target == nil or target == false then
    -- No alignment: just one space between title and tags.
    return left .. " " .. tags
  end
  local effective
  if target < 0 then
    local tw = opts.textwidth or 80
    effective = tw + target + 1
  elseif target == 0 then
    return left .. " " .. tags
  else
    effective = target
  end
  -- The tags' RIGHT edge should land at column `effective` (1-based).
  -- Width of left + tags = #left + pad + #tags.  Right edge column =
  -- #left + pad + #tags.  So pad = effective - #left - #tags.
  local pad = effective - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(tags)
  if pad < 1 then
    pad = 1 -- never overlap; degrade to single-space separation
  end
  return left .. string.rep(" ", pad) .. tags
end
M._normalize_headline = normalize_headline

-- Wrap a contiguous prose paragraph (already joined into one
-- string) to `width` chars per line, indenting continuation lines
-- by `cont_indent`.  Emacs's `fill-paragraph` is greedy
-- left-to-right — match that.
local function wrap_to_width(text, width, first_indent, cont_indent)
  if width <= 0 then
    return { first_indent .. text }
  end
  local out = {}
  local cur = first_indent
  for word in text:gmatch("%S+") do
    if cur == first_indent or cur == cont_indent then
      cur = cur .. word
    elseif #cur + 1 + #word <= width then
      cur = cur .. " " .. word
    else
      out[#out + 1] = cur
      cur = cont_indent .. word
    end
  end
  if cur ~= first_indent and cur ~= cont_indent then
    out[#out + 1] = cur
  end
  return out
end

-- Pure: take an array of input lines and return the rewrapped
-- array.  No buffer mutation, no globals — safe to call from
-- anywhere (LSP server, format-on-save plugin, tests).
--
-- `headline_opts` (optional) controls the headline normaliser:
--   { tags_column = N | false, normalize_whitespace = bool, textwidth = N }
-- Tables, lists, and other buffer-bound transformations are NOT
-- handled here -- format_buffer() runs those as separate passes
-- since they need a real bufnr (tablature.realign / list.repair).
-- Apply Emacs-style `org-adapt-indentation` to a line list AFTER
-- the prose-rewrap + headline-normalise pass.  Mode determines what
-- gets indented:
--
--   "headline-data" -- planning lines (SCHEDULED/DEADLINE/CLOSED),
--                      drawer open/close + body, property lines.
--                      Body PROSE stays at column 0 to match
--                      Emacs's default (org-adapt-indentation =
--                      'headline-data).  Most users want this.
--   true            -- every body line under a headline indents.
--                      Matches `org-adapt-indentation = t`.
--   false / nil     -- no-op; lines passed through unchanged.
--
-- shift = (level - 1) * shift_per_level for each body line.  Stars
-- on the headline itself are NEVER touched.
local function apply_adapt_indentation(lines, mode, shift_per_level)
  if not mode or mode == false then
    return lines
  end
  shift_per_level = shift_per_level or 2
  local indent_all = mode == true
  local out = {}
  local current_level = 0
  local in_block = false
  local in_drawer = false
  for _, line in ipairs(lines) do
    local stars = line:match("^(%*+)%s")
    if stars then
      current_level = #stars
      in_drawer = false
      out[#out + 1] = line
    elseif current_level == 0 then
      -- Pre-first-headline content (file directives, etc.) -- leave
      -- as-is.
      out[#out + 1] = line
    elseif is_block_open(line) then
      out[#out + 1] = line
      in_block = true
    elseif is_block_close(line) then
      out[#out + 1] = line
      in_block = false
    elseif in_block then
      -- Source / example block bodies are verbatim; never reindent.
      out[#out + 1] = line
    elseif line == "" then
      out[#out + 1] = line
    else
      local pad = string.rep(" ", (current_level - 1) * shift_per_level + 1)
      local stripped = line:gsub("^%s*", "")
      local was_in_drawer = in_drawer
      -- Flip drawer state BEFORE the indent decision so the `:END:`
      -- line is still treated as part of the drawer (indented), but
      -- the line AFTER it is back at column 0 (in headline-data
      -- mode).  Check `is_drawer_close` FIRST: `:END:` ALSO matches
      -- the looser drawer-open regex (`:NAME:` with NAME = "END"),
      -- so testing open first would re-set in_drawer = true and
      -- leak past the drawer.
      if is_drawer_close(line) then
        in_drawer = false
      elseif is_drawer_open(line) then
        in_drawer = true
      end
      local should_indent = indent_all
      if not should_indent then
        if is_planning(line) or is_drawer_open(line) or is_drawer_close(line) or was_in_drawer then
          should_indent = true
        end
      end
      if should_indent then
        out[#out + 1] = pad .. stripped
      else
        out[#out + 1] = line
      end
    end
  end
  return out
end
M._apply_adapt_indentation = apply_adapt_indentation

function M.format_lines(lines, width, headline_opts)
  width = width or 80
  local out = {}
  local in_block = false
  local in_drawer = false
  local i = 1
  -- A paragraph buffer.  We collect prose lines + their leading
  -- indent (from line 1) and bullet prefix (when starting under a
  -- list item) then flush via wrap_to_width when we hit a non-prose
  -- line or end of range.
  local para_lines = {}
  local para_first_indent
  local para_cont_indent
  local function flush_para()
    if #para_lines == 0 then
      return
    end
    local joined = table.concat(para_lines, " "):gsub("%s+", " ")
    joined = joined:gsub("^%s+", ""):gsub("%s+$", "")
    for _, l in
      ipairs(wrap_to_width(joined, width, para_first_indent or "", para_cont_indent or ""))
    do
      out[#out + 1] = l
    end
    para_lines, para_first_indent, para_cont_indent = {}, nil, nil
  end
  while i <= #lines do
    local line = lines[i]
    if in_block then
      flush_para()
      out[#out + 1] = line
      if is_block_close(line) then
        in_block = false
      end
    elseif in_drawer then
      flush_para()
      out[#out + 1] = line
      if is_drawer_close(line) then
        in_drawer = false
      end
    elseif is_block_open(line) then
      flush_para()
      out[#out + 1] = line
      in_block = true
    elseif is_drawer_open(line) then
      flush_para()
      out[#out + 1] = line
      in_drawer = true
    elseif is_headline(line) then
      flush_para()
      out[#out + 1] = normalize_headline(line, headline_opts or {})
    elseif is_planning(line) or is_directive(line) or is_table(line) or line == "" then
      flush_para()
      out[#out + 1] = line
    elseif is_list(line) then
      flush_para()
      -- Start a new para under this bullet.  Continuation indent
      -- aligns under the bullet's first text column.
      local bullet = line:match("^(%s*[%-%+%*]%s)") or line:match("^(%s*%d+[%.%)]%s)")
      local rest = line:sub(#bullet + 1)
      para_first_indent = bullet
      para_cont_indent = string.rep(" ", #bullet)
      para_lines[#para_lines + 1] = rest
    else
      -- Continuation of a prose paragraph (or first prose line).
      if not para_first_indent then
        local indent = leading_indent(line)
        para_first_indent = indent
        para_cont_indent = indent
      end
      para_lines[#para_lines + 1] = line:gsub("^%s+", "")
    end
    i = i + 1
  end
  flush_para()
  -- Adapt-indent post-pass.  When the user opts in via
  -- `indent.adapt_indentation`, body lines get repadded to match
  -- their parent headline's depth.  No-op when disabled.
  if headline_opts and headline_opts.adapt_indentation then
    out = apply_adapt_indentation(
      out,
      headline_opts.adapt_indentation,
      headline_opts.shift_per_level or 2
    )
  end
  return out
end

-- Read the user's headline-format options from organ.config.format,
-- expanding into the shape format_lines expects.
local function headline_opts_for(bufnr)
  local organ = require("organ")
  local cfg = (organ.config and organ.config.format) or {}
  local icfg = (organ.config and organ.config.indent) or {}
  return {
    tags_column = cfg.tags_column,
    normalize_whitespace = cfg.normalize_whitespace ~= false,
    textwidth = textwidth(bufnr),
    adapt_indentation = icfg.adapt_indentation,
    shift_per_level = icfg.shift_per_level or 2,
  }
end

-- Walk the buffer and call tablature's realign on each pipe-table
-- region.  Tables can't be aligned by a pure lines->lines pass --
-- realign needs the bufnr to read the actual rendered widths.
local function realign_tables(bufnr)
  local ok, table_mod = pcall(require, "organ.table")
  if not ok or not table_mod or not table_mod.realign then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local i = 1
  while i <= #lines do
    if lines[i]:match("^%s*|") then
      pcall(table_mod.realign, bufnr, i)
      -- Re-read lines after realign (line count may have shifted).
      total = vim.api.nvim_buf_line_count(bufnr)
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
      -- Skip past this table region.
      while i <= #lines and lines[i]:match("^%s*|") do
        i = i + 1
      end
    else
      i = i + 1
    end
  end
end

-- Walk the buffer and re-sequence ordered list numbering per
-- contiguous list block.  Bullet style is left alone; only `1.`/`2.`
-- numbering is repaired.
local function repair_lists(bufnr)
  local ok, list_mod = pcall(require, "organ.list")
  if not ok or not list_mod or not list_mod.repair then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local seen = {} -- 1-based start line of each block we've already repaired
  for i, l in ipairs(lines) do
    if l:match("^%s*%d+[%.%)]%s") and not seen[i] then
      pcall(list_mod.repair, bufnr, i)
      -- Mark the whole block as visited so we don't re-enter mid-block.
      local indent = (l:match("^(%s*)") or "")
      local j = i
      while j <= #lines and lines[j]:match("^" .. indent .. "%S") do
        seen[j] = true
        j = j + 1
      end
    end
  end
end

-- Format a 1-based inclusive line range in `bufnr` IN PLACE.
function M.format_range(bufnr, lo, hi)
  bufnr = bufnr or 0
  local total = vim.api.nvim_buf_line_count(bufnr)
  if lo < 1 then
    lo = 1
  end
  if hi > total then
    hi = total
  end
  if hi < lo then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo - 1, hi, false)
  local out = M.format_lines(lines, textwidth(bufnr), headline_opts_for(bufnr))
  vim.api.nvim_buf_set_lines(bufnr, lo - 1, hi, false, out)
end

function M.format_buffer(bufnr)
  bufnr = bufnr or 0
  -- 1. Pure lines->lines pass: prose rewrap + headline normalisation
  --    (tag right-align, whitespace collapse).
  M.format_range(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
  -- 2. Buffer-bound passes that can't be expressed as pure
  --    transformations: table cell alignment + ordered-list
  --    re-sequencing.  Order matters -- realign first because list
  --    repair re-reads line numbers and a re-aligned table can
  --    shift a list's start line.
  realign_tables(bufnr)
  repair_lists(bufnr)
end

-- Vim formatexpr entry point.  Reads `v:lnum` (start line) and
-- `v:count` (line count) from the formatexpr context and rewraps.
-- Returning 0 lets vim know the format succeeded; non-zero falls
-- back to the internal formatter.
function M.formatexpr()
  local lnum = vim.fn.eval("v:lnum")
  local count = vim.fn.eval("v:count")
  if not lnum or not count or count < 1 then
    return 1
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local ok = pcall(M.format_range, bufnr, lnum, lnum + count - 1)
  if ok then
    return 0
  end
  return 1
end

M.commands = {
  format = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      if cmd and cmd.range and cmd.range > 0 then
        M.format_range(bufnr, cmd.line1, cmd.line2)
      else
        M.format_buffer(bufnr)
      end
    end,
    range = true,
    desc = "Rewrap paragraphs in the buffer (or `:'<,'> Org format` for a range)",
  },
}

return M
