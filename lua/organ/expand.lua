-- Org-mode macro / SETUPFILE / INCLUDE expansion.
--
-- Three directives get processed here:
--
--   #+MACRO: name body with $1 $2 placeholders
--     defines a text macro; `{{{name(arg1, arg2)}}}` invokes it.
--   #+SETUPFILE: path
--     recursively loads another org file's #+KEYWORDS and #+MACROS
--     (text BODY is not pulled in — only directives).
--   #+INCLUDE: "file.org" [type] [:keys vals...]
--     verbatim/example/src/export-block insertion of another file's
--     content, optionally restricted to a line range or named block.
--
-- Plus built-in macros that don't need a #+MACRO: definition:
--   {{{date(FMT)}}}, {{{time(FMT)}}}, {{{modification-time(FMT)}}}
--   {{{title}}}, {{{author}}}, {{{email}}}, {{{date}}}
--   {{{property(KEY)}}}, {{{keyword(KEY)}}}
--   {{{n(VAR)}}}, {{{n(VAR,VAL)}}}                  -- counters
--
-- Order of operations on a buffer:
--   1. Resolve SETUPFILE chain (cycle-detected) into a directive ctx.
--   2. Expand INCLUDE directives in place.
--   3. Re-scan the result for any directives the includes brought in.
--   4. Expand macros (built-ins + user-defined).
--
-- Used by the export pipeline (markdown / html / latex / ascii /
-- texinfo / etc.) when opts.expand = true. Directly callable as
-- `:Org expand_preview` for ad-hoc previewing.

local M = {}

local obuf = require("organ.buf")
-- Directive scanning

-- Match any `#+KEYWORD: value` line. Returns iterator yielding (key, value)
-- in lower-case key form. Trims surrounding whitespace.
local function each_keyword(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local i = 0
  return function()
    while i < #lines do
      i = i + 1
      local k, v = lines[i]:match("^%s*#%+([%w_-]+):%s*(.-)%s*$")
      if k then
        return k:lower(), v, i
      end
    end
  end
end

-- Collect every `#+MACRO:` definition. Body is everything after the
-- first whitespace following the name. Last definition wins (matches
-- Emacs).
local function collect_macros_local(text, into)
  for k, v in each_keyword(text) do
    if k == "macro" then
      local name, body = v:match("^(%S+)%s*(.*)$")
      if name then
        into[name] = body or ""
      end
    end
  end
end

-- Collect every `#+KEYWORD:` directive into a flat lookup. Multi-valued
-- keywords (the same KEY appearing twice) are joined with a single
-- space, mirroring Emacs's behaviour for #+TITLE / #+AUTHOR / etc.
local function collect_keywords_local(text, into)
  for k, v in each_keyword(text) do
    if k ~= "macro" and k ~= "setupfile" and k ~= "include" then
      if into[k] then
        into[k] = into[k] .. " " .. v
      else
        into[k] = v
      end
    end
  end
end

-- SETUPFILE chain

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Resolve `path` against `base_dir` if it isn't absolute. Returns the
-- absolute path or nil.
local function resolve_path(path, base_dir)
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return path
  end
  if base_dir then
    return base_dir .. "/" .. path
  end
  return path
end

-- Recursively follow #+SETUPFILE: directives and merge their #+MACRO
-- and #+KEYWORD definitions into the supplied tables. Cycle-detected
-- via the `visited` set.
local function follow_setupfiles(text, base_dir, macros, keywords, visited)
  for k, v in each_keyword(text) do
    if k == "setupfile" and v ~= "" then
      -- Strip surrounding quotes.
      local path = v:gsub('^"(.+)"$', "%1"):gsub("^'(.+)'$", "%1")
      local resolved = resolve_path(path, base_dir)
      if resolved and not visited[resolved] then
        visited[resolved] = true
        local s = read_file(resolved)
        if s then
          local sub_dir = resolved:match("^(.+)/[^/]*$")
          -- Depth-first so a leaf SETUPFILE's definitions are
          -- overwritten by its parent's, matching include order.
          follow_setupfiles(s, sub_dir, macros, keywords, visited)
          collect_macros_local(s, macros)
          collect_keywords_local(s, keywords)
        end
      end
    end
  end
end

-- Public: build the directive context for `text` (typically the
-- buffer's whole source). `base_dir` is the directory used to resolve
-- relative SETUPFILE / INCLUDE paths — typically the org file's
-- containing directory.
function M.collect_directives(text, base_dir)
  local ctx = { macros = {}, keywords = {} }
  follow_setupfiles(text, base_dir, ctx.macros, ctx.keywords, {})
  collect_macros_local(text, ctx.macros)
  collect_keywords_local(text, ctx.keywords)
  return ctx
end

-- INCLUDE expansion

-- Parse the args of an `#+INCLUDE:` directive. Returns:
--   { path, type, lang, lines = {start, end}, search, minlevel,
--     only_contents = bool }
-- where `type` is one of "verbatim", "example", "export", "src".
local function parse_include(value)
  local out = { type = "verbatim" }
  -- Path: "..." or '...' first, then optional `::SEARCH`.
  local path
  local rest = value:gsub("^%s+", "")
  local q = rest:sub(1, 1)
  if q == '"' or q == "'" then
    local close = rest:find(q, 2, true)
    if not close then
      return nil
    end
    path = rest:sub(2, close - 1)
    rest = rest:sub(close + 1)
  else
    path, rest = rest:match("^(%S+)(.*)$")
  end
  if not path then
    return nil
  end
  local search = path:match("::(.+)$")
  if search then
    path = path:gsub("::.+$", "")
  end
  out.path = path
  out.search = search

  -- Type token (optional).
  rest = rest:gsub("^%s+", "")
  local first_tok = rest:match("^(%S+)")
  if first_tok and not first_tok:match("^:") then
    if
      first_tok == "example"
      or first_tok == "src"
      or first_tok == "export"
      or first_tok == "verbatim"
    then
      out.type = first_tok
      rest = rest:sub(#first_tok + 1):gsub("^%s+", "")
      if first_tok == "src" or first_tok == "export" then
        local lang = rest:match("^(%S+)")
        if lang and not lang:match("^:") then
          out.lang = lang
          rest = rest:sub(#lang + 1):gsub("^%s+", "")
        end
      end
    end
  end

  -- Headed properties: `:lines "5-10" :minlevel 2 :only-contents t`.
  for key, val in rest:gmatch(":(%S+)%s+([^:]+)") do
    val = val:gsub("%s+$", "")
    if key == "lines" then
      local lo, hi = val:gsub('"', ""):match("^(%d*)-(%d*)$")
      -- Emacs excludes the upper bound: "5-10" is lines 5 to 9.
      local last = tonumber(hi)
      out.lines = { tonumber(lo), last and last - 1 or nil }
    elseif key == "minlevel" then
      out.minlevel = tonumber(val)
    elseif key == "only-contents" then
      out.only_contents = (val:match("^[tT]") ~= nil)
    end
  end
  return out
end

-- Slice a list of lines [lo..hi] (1-based inclusive; nil = open end).
local function slice_lines(lines, lo, hi)
  lo = lo or 1
  hi = hi or #lines
  if lo < 1 then
    lo = 1
  end
  if hi > #lines then
    hi = #lines
  end
  local out = {}
  for i = lo, hi do
    out[#out + 1] = lines[i]
  end
  return out
end

-- Resolve `::SEARCH` against included content. Supports `*Headline`
-- (subtree of matching headline) and `#NAME` (named block, e.g.
-- `#+NAME: foo`). Returns the body lines or nil if not found.
local function locate_search(lines, search)
  if not search then
    return lines
  end
  if search:sub(1, 1) == "*" then
    local title = search:sub(2)
    local star_count, body_start
    for i, l in ipairs(lines) do
      local stars, rest = l:match("^(%*+) +(.+)$")
      if stars then
        local clean = rest:gsub("%s+:[%w_:@]+:%s*$", "")
        if clean == title or rest == title then
          star_count = #stars
          body_start = i
          break
        end
      end
    end
    if not body_start then
      return nil
    end
    -- Find next sibling-or-shallower headline.
    local body_end = #lines
    for j = body_start + 1, #lines do
      local stars = lines[j]:match("^(%*+) ")
      if stars and #stars <= star_count then
        body_end = j - 1
        break
      end
    end
    return slice_lines(lines, body_start, body_end)
  end
  if search:sub(1, 1) == "#" then
    local name = search:sub(2)
    for i, l in ipairs(lines) do
      local n = l:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.+)%s*$")
      if n and n == name then
        -- Find the block following the #+NAME.
        local body_start, body_end
        local j = i + 1
        local opener = lines[j] and lines[j]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
        if opener then
          body_start = j
          for k = j + 1, #lines do
            if lines[k]:match("^%s*#%+[Ee][Nn][Dd]_") then
              body_end = k
              break
            end
          end
        end
        if body_start and body_end then
          return slice_lines(lines, body_start, body_end)
        end
        return nil
      end
    end
    return nil
  end
  return lines
end

-- Promote / demote headlines so the topmost in the included content
-- starts at `minlevel`. Mirrors Emacs's behaviour. Modifies `lines`
-- in place and returns it.
local function adjust_levels(lines, minlevel)
  if not minlevel then
    return lines
  end
  -- Find the smallest existing headline level.
  local smallest
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+) ")
    if stars and (not smallest or #stars < smallest) then
      smallest = #stars
    end
  end
  if not smallest then
    return lines
  end
  local delta = minlevel - smallest
  if delta == 0 then
    return lines
  end
  for i, l in ipairs(lines) do
    local stars, rest = l:match("^(%*+)( .*)$")
    if stars then
      local new = #stars + delta
      if new < 1 then
        new = 1
      end
      lines[i] = string.rep("*", new) .. rest
    end
  end
  return lines
end

-- Wrap content per the include's type. `verbatim` returns body as-is.
local function wrap_include(body_lines, info)
  if info.type == "example" then
    local out = { "#+begin_example" }
    for _, l in ipairs(body_lines) do
      out[#out + 1] = l
    end
    out[#out + 1] = "#+end_example"
    return out
  end
  if info.type == "src" then
    local out = { "#+begin_src " .. (info.lang or "") }
    for _, l in ipairs(body_lines) do
      out[#out + 1] = l
    end
    out[#out + 1] = "#+end_src"
    return out
  end
  if info.type == "export" then
    local out = { "#+begin_export " .. (info.lang or "") }
    for _, l in ipairs(body_lines) do
      out[#out + 1] = l
    end
    out[#out + 1] = "#+end_export"
    return out
  end
  return body_lines
end

-- Recursively expand INCLUDE directives. `visited` carries paths
-- already expanded along this chain so a SETUPFILE/INCLUDE cycle
-- doesn't blow the stack.
function M.expand_includes(text, base_dir, visited)
  visited = visited or {}
  local lines = vim.split(text, "\n", { plain = true })
  local out = {}
  for _, line in ipairs(lines) do
    local val = line:match("^%s*#%+[Ii][Nn][Cc][Ll][Uu][Dd][Ee]:%s*(.+)%s*$")
    if val then
      local info = parse_include(val)
      if info and info.path then
        local resolved = resolve_path(info.path, base_dir)
        if resolved and not visited[resolved] then
          visited[resolved] = true
          local raw = read_file(resolved)
          if raw then
            local sub_dir = resolved:match("^(.+)/[^/]*$")
            -- Recurse first so transitively-included material gets
            -- the same treatment.
            raw = M.expand_includes(raw, sub_dir, visited)
            local body = vim.split(raw, "\n", { plain = true })
            -- Drop trailing empty line introduced by the split.
            if body[#body] == "" then
              body[#body] = nil
            end
            body = locate_search(body, info.search) or {}
            body = slice_lines(
              body,
              info.lines and info.lines[1] or nil,
              info.lines and info.lines[2] or nil
            )
            body = adjust_levels(body, info.minlevel)
            for _, b in ipairs(wrap_include(body, info)) do
              out[#out + 1] = b
            end
          end
          visited[resolved] = nil
        end
      end
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

-- Macro expansion

-- Built-in macros. `args` is the parenthesised arg list (already split
-- on commas, with whitespace trimmed); `ctx` is the directive ctx.
-- Return nil to fall through to user macros.
-- Epoch time of `value` when it is exactly one org timestamp (a range
-- counts as one; its start is used), else nil.
local function timestamp_time(value)
  local y, m, d, rest, after = value:match("^[<%[](%d%d%d%d)%-(%d%d)%-(%d%d)([^>%]]*)[>%]](.*)$")
  if not y or (after ~= "" and not after:match("^%-%-[<%[][^>%]]*[>%]]$")) then
    return nil
  end
  local h, mi = rest:match("(%d%d?):(%d%d)")
  return os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
  })
end

local function builtin_macro(name, args, ctx)
  if name == "date" then
    -- Emacs `org-macro-initialize-templates`: FMT applies only when
    -- #+DATE is a single timestamp; otherwise the raw value is used.
    local value = ctx.keywords.date
    if not value then
      return ""
    end
    if not args[1] or args[1] == "" then
      return value
    end
    local t = timestamp_time(vim.trim(value))
    if t then
      return os.date(args[1], t)
    end
    return value
  end
  if name == "time" then
    local fmt = (args[1] and args[1] ~= "") and args[1] or "%H:%M"
    return os.date(fmt)
  end
  if name == "modification-time" then
    local fmt = (args[1] and args[1] ~= "") and args[1] or "%Y-%m-%d"
    if ctx.file_path then
      local stat = vim.uv.fs_stat(ctx.file_path)
      if stat then
        return os.date(fmt, stat.mtime.sec)
      end
    end
    return os.date(fmt)
  end
  if name == "title" then
    return ctx.keywords.title or ""
  end
  if name == "author" then
    return ctx.keywords.author or ""
  end
  if name == "email" then
    return ctx.keywords.email or ""
  end
  if name == "keyword" then
    return ctx.keywords[(args[1] or ""):lower()] or ""
  end
  if name == "property" then
    local key = (args[1] or ""):upper()
    return (ctx.properties and ctx.properties[key]) or ""
  end
  if name == "n" then
    local var = args[1] or ""
    local val = args[2]
    ctx._counters = ctx._counters or {}
    if val and val ~= "" then
      local n = tonumber(val)
      if n then
        ctx._counters[var] = n
        return tostring(n)
      end
      ctx._counters[var] = 1
      return "1"
    end
    ctx._counters[var] = (ctx._counters[var] or 0) + 1
    return tostring(ctx._counters[var])
  end
  return nil
end

-- Split a macro arg list on commas, respecting backslash-escaping
-- (`\,`) so users can pass a literal comma inside an arg.
local function split_args(s)
  local out, buf = {}, {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" and s:sub(i + 1, i + 1) == "," then
      buf[#buf + 1] = ","
      i = i + 2
    elseif c == "," then
      out[#out + 1] = table.concat(buf):gsub("^%s+", ""):gsub("%s+$", "")
      buf = {}
      i = i + 1
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  out[#out + 1] = table.concat(buf):gsub("^%s+", ""):gsub("%s+$", "")
  return out
end

-- Substitute $1..$9 placeholders in a user-defined macro body.
local function substitute_placeholders(body, args)
  return (body:gsub("%$(%d)", function(d)
    local n = tonumber(d)
    return args[n] or ""
  end))
end

-- Replace every `{{{name(args)}}}` (or `{{{name}}}`) in `text`.
-- Loops to a fixed point so a macro can expand into another macro.
function M.expand_macros(text, ctx, max_passes)
  max_passes = max_passes or 8
  for _ = 1, max_passes do
    local changed = false
    -- An undefined macro is left verbatim. Emacs aborts the whole export
    -- at this point; expansion runs on every organ export, so silently
    -- deleting the text the user wrote would be the worse of the two.
    local replaced = text:gsub("{{{([%w_-]+)(%b())}}}", function(name, paren)
      local args = split_args(paren:sub(2, -2))
      local b = builtin_macro(name, args, ctx)
      if b ~= nil then
        changed = true
        return b
      end
      local body = ctx.macros[name]
      if body then
        changed = true
        return substitute_placeholders(body, args)
      end
      return nil
    end)
    replaced = replaced:gsub("{{{([%w_-]+)}}}", function(name)
      local b = builtin_macro(name, {}, ctx)
      if b ~= nil then
        changed = true
        return b
      end
      local body = ctx.macros[name]
      if body then
        changed = true
        return body
      end
      return nil
    end)
    text = replaced
    if not changed then
      break
    end
  end
  return text
end

-- High-level driver

-- Run the full directive pass: SETUPFILE → INCLUDE → re-scan macros →
-- expand macros. Returns the rewritten text plus the directive ctx.
--
-- opts:
--   base_dir   directory for relative SETUPFILE / INCLUDE paths
--   file_path  used by {{{modification-time}}} for mtime lookup
--   properties { KEY = value } for {{{property(KEY)}}}
--   include    set to false to skip INCLUDE expansion
--   macros     set to false to skip macro expansion
function M.process(text, opts)
  opts = opts or {}
  local base_dir = opts.base_dir
  local ctx = M.collect_directives(text, base_dir)
  ctx.file_path = opts.file_path
  ctx.properties = opts.properties or {}
  if opts.include ~= false then
    text = M.expand_includes(text, base_dir, {})
    -- Includes can carry MACRO / SETUPFILE — re-collect.
    ctx = M.collect_directives(text, base_dir)
    ctx.file_path = opts.file_path
    ctx.properties = opts.properties or {}
  end
  if opts.macros ~= false then
    text = M.expand_macros(text, ctx)
  end
  return text, ctx
end

M.commands = {
  expand_preview = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, "\n")
      local name = vim.api.nvim_buf_get_name(bufnr)
      local base_dir = (name and name ~= "") and vim.fs.dirname(name) or nil
      local out = M.process(text, {
        base_dir = base_dir,
        file_path = (name and name ~= "") and name or nil,
      })
      vim.cmd("vnew")
      obuf.set_lines(0, 0, -1, vim.split(out, "\n", { plain = true }))
      vim.bo.filetype = "org"
      vim.bo.bufhidden = "wipe"
      vim.bo.buftype = "nofile"
    end,
    desc = "Preview macros / SETUPFILE / INCLUDE expanded for the current buffer",
  },
}

return M
