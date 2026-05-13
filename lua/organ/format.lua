-- Org-mode formatter.  Composable pure passes that read config from
-- `organ.config.format`.  Format-on-save is intentionally NOT a
-- knob here -- conform.nvim, none-ls, the built-in LSP
-- `textDocument/formatting`, and a 3-line user-wired BufWritePre
-- autocmd all drive `M.format_buffer` cleanly.  See the README
-- "Formatting" section for recipes.

local M = {}

local obuf = require("organ.buf")
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
  return line:match("^(%s*)[%-%+%*]%s") ~= nil or line:match("^(%s*)%d+[%.%)]%s") ~= nil
end
local function leading_indent(line)
  return line:match("^(%s*)") or ""
end

local function effective_width(bufnr, cfg)
  local explicit = (cfg.wrap or {}).width
  if explicit and explicit > 0 then
    return explicit
  end
  if bufnr then
    local tw = vim.bo[bufnr].textwidth
    if tw and tw > 0 then
      return tw
    end
  end
  return 80
end

local function format_cfg()
  local ok, organ = pcall(require, "organ")
  if ok and organ.config and require("organ.buf_config").read(nil, "format") then
    return require("organ.buf_config").read(nil, "format")
  end
  return {}
end

local function trim_trailing_whitespace(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:gsub("%s+$", "")
  end
  return out
end

local function split_trailing_tags(s)
  local body, tags = s:match("^(.-)%s+(:[%w_@#%%][%w_@#%%:]*:)%s*$")
  if body and tags then
    return body, tags
  end
  return s, nil
end

-- Resolve a `tags_column` config value to a placement directive.
-- Returns either nil (no alignment, caller emits a single-space gap)
-- or a table:
--   { kind = "flush" }                          -> one space between title and tags
--   { kind = "left",  column = N (int >= 1) }   -> tag block's LEFT edge at col N
--   { kind = "right", column = N (int >= 1) }   -> tag block's RIGHT edge at col N
--
-- Accepted shapes for `value`:
--   positive integer N       -> { kind = "left",  column = N }   (Emacs compat)
--   negative integer N       -> { kind = "right", column = |N| } (Emacs compat)
--   0                        -> { kind = "flush" }
--   false                    -> nil (no alignment)
--   "textwidth"              -> right edge at vim.bo[bufnr].textwidth
--                               (falls back to 80 when textwidth is 0/unset)
--   "textwidth+N" / "-N"     -> right edge at textwidth +/- N
--   "winwidth"               -> right edge at nvim_win_get_width(winid)
--   "winwidth+N" / "-N"      -> right edge at winwidth +/- N
--   function                 -> result recursively resolved
--
-- `bufnr` defaults to 0 (current); `winid` defaults to 0 (current).
function M._resolve_tags_column(value, bufnr, winid)
  if type(value) == "function" then
    local ok, inner = pcall(value)
    if not ok then
      return nil
    end
    return M._resolve_tags_column(inner, bufnr, winid)
  end
  if value == nil or value == false then
    return nil
  end
  if value == 0 then
    return { kind = "flush" }
  end
  if type(value) == "number" then
    if value > 0 then
      return { kind = "left", column = math.floor(value) }
    end
    return { kind = "right", column = -math.floor(value) }
  end
  if type(value) == "string" then
    local base, sign, num = value:match("^(%w+)([%+%-]?)(%d*)$")
    if not base then
      return nil
    end
    -- Reject "textwidth+" / "textwidth-" (sign without number) and
    -- "textwidthabc" (no sign, trailing garbage).  Either both empty
    -- (bare "textwidth") or both non-empty is allowed.
    if (sign == "" and num ~= "") or (sign ~= "" and num == "") then
      return nil
    end
    local offset = 0
    if sign ~= "" and num ~= "" then
      offset = tonumber(num) or 0
      if sign == "-" then
        offset = -offset
      end
    end
    local b = bufnr or 0
    local w = winid or 0
    local base_val
    if base == "textwidth" then
      local ok, tw = pcall(function()
        return vim.bo[b].textwidth
      end)
      base_val = (ok and tw) or 0
      if base_val == 0 then
        base_val = 80
      end
    elseif base == "winwidth" then
      local ok, ww = pcall(vim.api.nvim_win_get_width, w)
      base_val = (ok and ww) or 80
    else
      return nil
    end
    local column = base_val + offset
    if column < 1 then
      column = 1
    end
    return { kind = "right", column = column }
  end
  return nil
end

-- Compute the padded headline string for "<left><pad><tags>".  Aligns
-- the tag block to `opts.tags_column` (or, when nil,
-- `config.format.headline.tags_column`, falling back to "textwidth").
-- See M._resolve_tags_column for accepted value shapes.
--
-- When `tags` is "" or nil, returns `left` unchanged.  Otherwise
-- returns `left .. pad_spaces .. tags` with `pad >= 1` so the tag
-- block never abuts a non-space character.
function M.align_tag_block(left, tags, opts)
  if tags == nil or tags == "" then
    return left
  end
  opts = opts or {}
  local cfg_val = opts.tags_column
  if cfg_val == nil then
    cfg_val = (format_cfg().headline or {}).tags_column
    if cfg_val == nil then
      cfg_val = "textwidth"
    end
  end
  local resolved = M._resolve_tags_column(cfg_val, opts.bufnr, opts.winid)
  if resolved == nil or resolved.kind == "flush" then
    return left .. " " .. tags
  end
  local left_w = vim.fn.strdisplaywidth(left)
  local tags_w = vim.fn.strdisplaywidth(tags)
  local left_edge
  if resolved.kind == "left" then
    left_edge = resolved.column
  else
    -- "right": tag's right edge at resolved.column; left edge at column - tags_w
    left_edge = resolved.column - tags_w
  end
  local pad = left_edge - left_w
  if pad < 1 then
    pad = 1
  end
  return left .. string.rep(" ", pad) .. tags
end

local function normalize_headline(line, opts)
  opts = opts or {}
  if opts.normalize_whitespace == false and not opts.tags_column then
    return line
  end
  local stars, rest = line:match("^(%*+)%s+(.-)%s*$")
  if not stars then
    return line
  end
  local body, tags = split_trailing_tags(rest)
  body = body:gsub("%s+$", ""):gsub("^%s+", "")

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
  do
    local first, after = body:match("^(%S+)%s+()")
    if first and todo_kw_set[first] then
      pieces[#pieces + 1] = first
      cursor = after
    end
  end
  do
    local sub = body:sub(cursor)
    local kw, after = sub:match("^(COMMENT)%s+()")
    if kw then
      pieces[#pieces + 1] = kw
      cursor = cursor + (after - 1)
    end
  end
  do
    local sub = body:sub(cursor)
    local cookie, after = sub:match("^(%[#[%u%d]%])%s*()")
    if cookie then
      pieces[#pieces + 1] = cookie
      cursor = cursor + (after - 1)
    end
  end
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
  -- `opts.tags_column == nil` here means "caller did not pass an explicit
  -- target", which inside the formatter pipeline (`normalize_headlines`)
  -- means "leave tags wherever the user typed them"; flip nil to false so
  -- the helper takes the flush-with-one-space branch rather than reading
  -- the config default.
  local target = opts.tags_column
  if target == nil then
    target = false
  end
  return M.align_tag_block(left, tags, { tags_column = target })
end
M._normalize_headline = normalize_headline

local function normalize_headlines(lines, cfg)
  local hcfg = cfg.headline or {}
  if hcfg.normalize_whitespace == false and hcfg.tags_column == nil then
    return lines
  end
  local opts = {
    normalize_whitespace = hcfg.normalize_whitespace ~= false,
    tags_column = hcfg.tags_column,
  }
  local out = {}
  for i, line in ipairs(lines) do
    if is_headline(line) then
      out[i] = normalize_headline(line, opts)
    else
      out[i] = line
    end
  end
  return out
end

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

local function wrap_prose(lines, cfg)
  if (cfg.wrap or {}).enabled == false then
    return lines
  end
  local width = cfg._effective_width or 80
  local out = {}
  local in_block = false
  local in_drawer = false
  local para_lines, para_first, para_cont = {}, nil, nil

  local function flush()
    if #para_lines == 0 then
      return
    end
    local joined = table.concat(para_lines, " "):gsub("%s+", " ")
    joined = joined:gsub("^%s+", ""):gsub("%s+$", "")
    for _, l in ipairs(wrap_to_width(joined, width, para_first or "", para_cont or "")) do
      out[#out + 1] = l
    end
    para_lines, para_first, para_cont = {}, nil, nil
  end

  for _, line in ipairs(lines) do
    if in_block then
      flush()
      out[#out + 1] = line
      if is_block_close(line) then
        in_block = false
      end
    elseif in_drawer then
      flush()
      out[#out + 1] = line
      if is_drawer_close(line) then
        in_drawer = false
      end
    elseif is_block_open(line) then
      flush()
      out[#out + 1] = line
      in_block = true
    elseif is_drawer_open(line) then
      flush()
      out[#out + 1] = line
      in_drawer = true
    elseif
      is_headline(line)
      or is_planning(line)
      or is_directive(line)
      or is_table(line)
      or line == ""
    then
      flush()
      out[#out + 1] = line
    elseif is_list(line) then
      flush()
      local bullet = line:match("^(%s*[%-%+%*]%s)") or line:match("^(%s*%d+[%.%)]%s)")
      local rest = line:sub(#bullet + 1)
      para_first = bullet
      para_cont = string.rep(" ", #bullet)
      para_lines[#para_lines + 1] = rest
    else
      if not para_first then
        local indent = leading_indent(line)
        para_first = indent
        para_cont = indent
      end
      para_lines[#para_lines + 1] = line:gsub("^%s+", "")
    end
  end
  flush()
  return out
end

local function adapt_indentation(lines, mode, shift_per_level)
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
      out[#out + 1] = line
    elseif is_block_open(line) then
      out[#out + 1] = line
      in_block = true
    elseif is_block_close(line) then
      out[#out + 1] = line
      in_block = false
    elseif in_block then
      out[#out + 1] = line
    elseif line == "" then
      out[#out + 1] = line
    else
      local pad = string.rep(" ", (current_level - 1) * shift_per_level + 1)
      local stripped = line:gsub("^%s*", "")
      local was_in_drawer = in_drawer
      -- Flip drawer state BEFORE the indent decision so the `:END:` line
      -- is still treated as part of the drawer.  Order matters: `:END:`
      -- ALSO matches the looser drawer-open regex (it's a `:NAME:` with
      -- NAME = "END"), so testing open first would re-set in_drawer.
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
M._apply_adapt_indentation = adapt_indentation

-- Pad `:KEY:` so values inside a property drawer line up past the
-- longest key.  Lines that don't match `:KEY: value` (LOGBOOK notes
-- etc.) are left alone.
local function align_drawer_values(lines, cfg)
  local dcfg = cfg.drawers or {}
  if dcfg.align_values == false then
    return lines
  end
  local min_indent = dcfg.min_value_indent or 1
  if min_indent < 1 then
    min_indent = 1
  end
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local line = lines[i]
    if not is_drawer_open(line) or is_drawer_close(line) then
      out[#out + 1] = line
      i = i + 1
    else
      local body_start = i + 1
      local body_end
      for j = body_start, n do
        if is_drawer_close(lines[j]) then
          body_end = j
          break
        end
      end
      if not body_end then
        out[#out + 1] = line
        i = i + 1
      else
        out[#out + 1] = line
        local max_key = 0
        for j = body_start, body_end - 1 do
          local _, key = lines[j]:match("^(%s*)(:[%w_-]+:)%s+%S")
          if key and #key > max_key then
            max_key = #key
          end
        end
        for j = body_start, body_end - 1 do
          local body_line = lines[j]
          local indent, key, val = body_line:match("^(%s*)(:[%w_-]+:)%s+(.*)$")
          if indent and key and val and val ~= "" then
            local pad = max_key - #key + min_indent
            out[#out + 1] = indent .. key .. string.rep(" ", pad) .. val
          else
            out[#out + 1] = body_line
          end
        end
        out[#out + 1] = lines[body_end]
        i = body_end + 1
      end
    end
  end
  return out
end

-- Enforce blank-line policy: `before_headline` / `before_block`
-- (insert / collapse to N blanks before each), and `collapse_runs`
-- (cap runs of consecutive blanks to N).
local function apply_blanks(lines, cfg)
  cfg = cfg or {}
  local before_h = cfg.before_headline
  local before_b = cfg.before_block
  local collapse = cfg.collapse_runs or 0

  local function enforce_n_before(out, n)
    while #out > 0 and out[#out] == "" do
      out[#out] = nil
    end
    if #out == 0 then
      return
    end
    for _ = 1, n do
      out[#out + 1] = ""
    end
  end

  local out = {}
  local blank_run = 0
  for _, line in ipairs(lines) do
    if line == "" then
      blank_run = blank_run + 1
      if not (collapse > 0 and blank_run > collapse) then
        out[#out + 1] = ""
      end
    else
      blank_run = 0
      if is_headline(line) and type(before_h) == "number" then
        enforce_n_before(out, before_h)
      elseif is_block_open(line) and type(before_b) == "number" then
        enforce_n_before(out, before_b)
      end
      out[#out + 1] = line
    end
  end
  return out
end

local function trim_eof(lines, cfg)
  cfg = cfg or {}
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l
  end
  if cfg.trim_trailing ~= false then
    while #out > 0 and out[#out] == "" do
      out[#out] = nil
    end
  end
  return out
end

-- Realign every pipe-table that intersects [lo, hi].  When lo/hi are
-- nil the whole buffer is walked.  Realign goes through tablature
-- (organ.table.realign -> tablature.realign) so the output matches
-- exactly what pressing Tab in a table cell produces -- consistency
-- across `:Org format`, `:Org format <range>`, `gq`/formatexpr and
-- format-on-save is the contract.
local function realign_tables(bufnr, lo, hi)
  local ok, table_mod = pcall(require, "organ.table")
  if not ok or not table_mod or not table_mod.realign then
    return
  end
  lo = lo or 1
  local i = 1
  while i <= vim.api.nvim_buf_line_count(bufnr) do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if line:match("^%s*|") then
      local table_start = i
      while i <= vim.api.nvim_buf_line_count(bufnr) do
        local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
        if not l:match("^%s*|") then
          break
        end
        i = i + 1
      end
      local table_end = i - 1
      local within = table_end >= lo and (not hi or table_start <= hi)
      if within then
        pcall(table_mod.realign, bufnr, table_start)
      end
    else
      i = i + 1
    end
  end
end

local function repair_lists(bufnr)
  local ok, list_mod = pcall(require, "organ.list")
  if not ok or not list_mod or not list_mod.repair then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local seen = {}
  for i, l in ipairs(lines) do
    if l:match("^%s*%d+[%.%)]%s") and not seen[i] then
      pcall(list_mod.repair, bufnr, i)
      local indent = (l:match("^(%s*)") or "")
      local j = i
      while j <= #lines and lines[j]:match("^" .. indent .. "%S") do
        seen[j] = true
        j = j + 1
      end
    end
  end
end

function M.format_lines(lines, cfg, bufnr)
  cfg = cfg or format_cfg()
  cfg._effective_width = effective_width(bufnr, cfg)

  if cfg.trim_trailing_whitespace ~= false then
    lines = trim_trailing_whitespace(lines)
  end
  lines = normalize_headlines(lines, cfg)
  lines = wrap_prose(lines, cfg)
  do
    local icfg = require("organ.buf_config").read(nil, "indent") or {}
    if icfg.adapt_indentation then
      lines = adapt_indentation(lines, icfg.adapt_indentation, icfg.shift_per_level or 2)
    end
  end
  lines = align_drawer_values(lines, cfg)
  lines = apply_blanks(lines, cfg.blanks or {})
  lines = trim_eof(lines, cfg.blanks or {})
  return lines
end

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
  local cfg = format_cfg()
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo - 1, hi, false)
  local out = M.format_lines(lines, cfg, bufnr)
  obuf.set_lines(bufnr, lo - 1, hi, out)
  if (cfg.tables or {}).realign ~= false then
    realign_tables(bufnr, lo, hi)
  end
end

function M.format_buffer(bufnr)
  bufnr = bufnr or 0
  local cfg = format_cfg()
  M.format_range(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
  if (cfg.lists or {}).repair_numbering ~= false then
    repair_lists(bufnr)
  end
  if (cfg.blanks or {}).ensure_final_newline ~= false then
    local last = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
    if last and last ~= "" then
      obuf.set_lines(bufnr, -1, -1, { "" })
    end
  end
end

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
    desc = "Format the buffer (or `:'<,'> Org format` for a range)",
  },
}

return M
