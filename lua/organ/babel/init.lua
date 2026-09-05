-- Org-Babel: execute #+BEGIN_SRC blocks and tangle them to files.
--
-- Header arguments come from, in increasing precedence: #+PROPERTY:
-- header-args / header-args:<lang>, the nearest enclosing subtree's
-- :header-args: / :header-args:<lang>: properties, the #+begin_src line,
-- and #+HEADER: lines directly above the block.
--
-- Supported header args:
--   :results value | output        what to capture
--   :results raw | silent | none | append | prepend | table | list |
--            drawer | html | latex | org | code | file
--   :wrap <block>                  wrap the result in #+begin_<block>
--   :exports code | results | both | none    (read by the exporter)
--   :tangle <file> | yes           destination for :Org babel tangle; yes
--                                  means <org basename>.<lang ext>
--   :var KEY=VALUE                 a literal value, or the name of another
--                                  block whose result is substituted
--   :dir <dir>                     run in this working directory
--   :noweb yes | tangle | eval | no-export | strip-export
--   :shebang :comments :padline :mkdirp      tangle-time options
--   :cache yes                     skip re-running while the body is unchanged
--   :session <name>                persistent interpreter (babel.sessions)
--
-- Built-in languages: sh, bash, python, lua and more; register others via
-- M.languages.
--
-- Security: every execute prompts via vim.fn.confirm unless
-- config.babel.confirm_evaluate = false OR the language appears in
-- config.babel.allow_languages = { "sh", "python", ... }.

local M = {}

local obuf = require("organ.buf")
-- Per-language runner. Each runner takes (body, opts) where opts has
-- { vars = { KEY = "VAL" }, dir = "/abs/path" } and returns (stdout, stderr, exit_code).
M.languages = {}

M.DEFAULT_TIMEOUT_MS = 60000

-- Resolve a :dir header value. `~` and `$VAR` expand; a path that is not a
-- directory is reported rather than handed to jobstart, which throws.
local function resolve_dir(dir)
  if not dir or dir == "" then
    return nil, nil
  end
  local path = vim.fn.expand(dir)
  if vim.fn.isdirectory(path) == 0 then
    return nil, ":dir is not a directory: " .. dir
  end
  return path, nil
end

local function run_subprocess(cmd, opts, body)
  local cwd, dir_err = resolve_dir(opts.dir)
  if dir_err then
    return "", dir_err, -1
  end
  local env = nil
  if opts.vars and next(opts.vars) then
    env = {}
    for k, v in pairs(opts.vars) do
      env[k] = tostring(v)
    end
  end
  local out_lines = {}
  local err_lines = {}
  local rc, exited = nil, false
  local job = vim.fn.jobstart(cmd, {
    cwd = cwd,
    env = env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        out_lines[#out_lines + 1] = l
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        err_lines[#err_lines + 1] = l
      end
    end,
    on_exit = function(_, code)
      rc, exited = code, true
    end,
  })
  if job <= 0 then
    return "", "failed to start " .. table.concat(cmd, " "), -1
  end
  if body and body ~= "" then
    vim.fn.chansend(job, body)
    vim.fn.chanclose(job, "stdin")
  end
  local timeout = tonumber(opts.timeout_ms) or M.DEFAULT_TIMEOUT_MS
  -- vim.wait keeps the event loop running, so callbacks fire and the user
  -- can interrupt with CTRL-C; jobwait blocks nvim outright.
  local done, why = vim.wait(timeout, function()
    return exited
  end, 20)
  local aborted
  if not done then
    pcall(vim.fn.jobstop, job)
    vim.wait(2000, function()
      return exited
    end, 20)
    aborted = table.concat(cmd, " ")
      .. ": "
      .. (why == -2 and "interrupted" or ("timed out after " .. timeout .. "ms"))
    rc = rc or -1
  end
  -- Strip trailing empty line that nvim adds.
  if out_lines[#out_lines] == "" then
    out_lines[#out_lines] = nil
  end
  if err_lines[#err_lines] == "" then
    err_lines[#err_lines] = nil
  end
  if aborted then
    err_lines[#err_lines + 1] = aborted
  end
  return table.concat(out_lines, "\n"), table.concat(err_lines, "\n"), rc or -1
end

-- Built-in language runners.
--
-- Each runner takes `body` (string) + `opts` ({ vars, dir }), spawns a
-- subprocess, pipes the body to stdin where appropriate, captures stdout +
-- stderr + rc, and returns (stdout, stderr, rc).
--
-- Runners that need a temp file (compiled languages -- c/cpp/rust/go/java)
-- write the body to /tmp/organ-babel-<lang>-<hash>.<ext>, compile, run.
--
-- Patches: each runner is `M.languages.<lang> = function(body, opts) ... end`
-- so users can override or add their own:
--   M.languages.haxe = function(body, opts)
--     return run_subprocess({ "haxe", "--interp", "-main", "Main" }, opts, body)
--   end
--
-- "stdin" runners pipe the body in via stdin; the language's binary reads
-- from "-" or stdin. "tempfile" runners write the body to a tempfile and
-- pass its path. "tempdir" runners need a working directory (Java for the
-- .class file, Rust/Go for cargo/go modules).

-- Convenience: stdin runner.
local function stdin(cmd_args)
  return function(body, opts)
    return run_subprocess(cmd_args, opts, body)
  end
end

-- Convenience: tempfile runner. The body is written to <tmpdir>/main.<ext>
-- and the produced path is appended to `cmd_args`. The compiled binary,
-- if any, lives in the same tmpdir.
local function tempfile(ext, builder)
  return function(body, opts)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local src = dir .. "/main." .. ext
    local fh, err = io.open(src, "w")
    if not fh then
      return "", "tempfile open: " .. tostring(err), -1
    end
    fh:write(body)
    fh:close()
    local cmd = builder(src, dir)
    local out, errstr, rc = run_subprocess(cmd, opts, nil)
    pcall(vim.fn.delete, dir, "rf")
    return out, errstr, rc
  end
end

-- Compiled tempfile runner: builds with `compile_args`, then runs the
-- produced binary at `dir/main`. Returns the run output. On compile error,
-- surfaces the compiler stderr immediately.
local function compiled(ext, compile_args_fn, run_args_fn)
  return function(body, opts)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local src = dir .. "/main." .. ext
    local fh, err = io.open(src, "w")
    if not fh then
      return "", "tempfile open: " .. tostring(err), -1
    end
    fh:write(body)
    fh:close()
    local compile_cmd = compile_args_fn(src, dir)
    local _, cerr, crc = run_subprocess(compile_cmd, opts, nil)
    if crc ~= 0 then
      pcall(vim.fn.delete, dir, "rf")
      return "", "compile failed: " .. cerr, crc
    end
    local run_cmd = run_args_fn(src, dir)
    local out, rerr, rrc = run_subprocess(run_cmd, opts, nil)
    pcall(vim.fn.delete, dir, "rf")
    return out, rerr, rrc
  end
end

-- Shells.
M.languages.sh = stdin({ "sh" })
M.languages.bash = stdin({ "bash" })
M.languages.zsh = stdin({ "zsh" })
M.languages.fish = stdin({ "fish" })

-- Scripting languages that read from stdin.
M.languages.python = stdin({ "python3", "-" })
M.languages.lua = stdin({ "lua", "-" })
M.languages.ruby = stdin({ "ruby", "-" })
M.languages.perl = stdin({ "perl", "-" })
M.languages.javascript = stdin({ "node", "-" })
M.languages.js = M.languages.javascript
M.languages.php = function(body, opts)
  return run_subprocess({ "php", "-r", body }, opts, nil)
end
M.languages.R = stdin({ "Rscript", "-" })
M.languages.r = M.languages.R

-- Tempfile-via-interpreter languages.
M.languages.typescript = tempfile("ts", function(src)
  return { "tsx", src }
end)
M.languages.ts = M.languages.typescript
M.languages.scheme = tempfile("scm", function(src)
  return { "scheme", "--script", src }
end)
M.languages.racket = tempfile("rkt", function(src)
  return { "racket", src }
end)
M.languages.ocaml = tempfile("ml", function(src)
  return { "ocaml", src }
end)
M.languages.haskell = tempfile("hs", function(src)
  return { "runghc", src }
end)
M.languages.elixir = tempfile("exs", function(src)
  return { "elixir", src }
end)
M.languages.clojure = tempfile("clj", function(src)
  return { "clojure", src }
end)

-- Compiled languages.
M.languages.c = compiled("c", function(src, dir)
  return { "cc", "-O0", "-o", dir .. "/main", src }
end, function(_, dir)
  return { dir .. "/main" }
end)

M.languages.cpp = compiled("cpp", function(src, dir)
  return { "c++", "-O0", "-o", dir .. "/main", src }
end, function(_, dir)
  return { dir .. "/main" }
end)

M.languages.rust = compiled("rs", function(src, dir)
  return { "rustc", "-O", "-o", dir .. "/main", src }
end, function(_, dir)
  return { dir .. "/main" }
end)

M.languages.go = compiled("go", function(src, dir)
  return { "go", "build", "-o", dir .. "/main", src }
end, function(_, dir)
  return { dir .. "/main" }
end)

-- Java needs the class to live in <dir>/Main.java; we rename src on disk.
M.languages.java = function(body, opts)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local src = dir .. "/Main.java"
  local fh, err = io.open(src, "w")
  if not fh then
    return "", "tempfile open: " .. tostring(err), -1
  end
  fh:write(body)
  fh:close()
  local _, cerr, crc = run_subprocess({ "javac", src }, opts, nil)
  if crc ~= 0 then
    pcall(vim.fn.delete, dir, "rf")
    return "", "javac failed: " .. cerr, crc
  end
  local out, rerr, rrc = run_subprocess({ "java", "-cp", dir, "Main" }, opts, nil)
  pcall(vim.fn.delete, dir, "rf")
  return out, rerr, rrc
end

-- SQL -- pipe body to sqlite3. Database is :memory: by default; users can
-- override via :var DB=<path>.
M.languages.sql = function(body, opts)
  local db = (opts.vars or {}).DB or ":memory:"
  return run_subprocess({ "sqlite3", db }, opts, body)
end
M.languages.sqlite = M.languages.sql

-- Rest helpers (URL via curl). Body should be a single line URL or a
-- compact verb + url like "GET https://api.example.com".
M.languages.rest = function(body, opts)
  body = body:gsub("^%s+", ""):gsub("%s+$", "")
  local verb, url = body:match("^(%u+)%s+(.+)$")
  if verb and url then
    return run_subprocess({ "curl", "-s", "-X", verb, url }, opts, nil)
  end
  return run_subprocess({ "curl", "-s", body }, opts, nil)
end

-- Split header text at each ":" that follows whitespace, keeping quoted
-- strings and bracketed groups intact (org-babel-balanced-split).
local function split_header_args(rest)
  local chunks, buf = {}, {}
  local depth, quoted, prev = 0, false, " "
  local i = 1
  while i <= #rest do
    local c = rest:sub(i, i)
    if quoted then
      buf[#buf + 1] = c
      if c == "\\" and i < #rest then
        i = i + 1
        buf[#buf + 1] = rest:sub(i, i)
      elseif c == '"' then
        quoted = false
      end
    elseif c == '"' then
      quoted = true
      buf[#buf + 1] = c
    elseif c == "(" or c == "[" then
      depth = depth + 1
      buf[#buf + 1] = c
    elseif c == ")" or c == "]" then
      depth = math.max(0, depth - 1)
      buf[#buf + 1] = c
    elseif c == ":" and depth == 0 and prev:match("%s") then
      chunks[#chunks + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = c
    end
    prev = c
    i = i + 1
  end
  chunks[#chunks + 1] = table.concat(buf)
  return chunks
end

local function unquote(val)
  local inner = val:match('^"(.*)"$')
  if not inner then
    return val
  end
  return (inner:gsub('\\(["\\])', "%1"))
end

-- Mutually exclusive :results values (org-babel-common-header-args-w-values):
-- a later value silences the earlier members of its own group only.
local RESULTS_GROUPS = {
  { "file", "list", "vector", "table", "scalar", "verbatim" },
  { "raw", "html", "latex", "org", "code", "pp", "drawer", "link", "graphics" },
  { "replace", "silent", "none", "discard", "append", "prepend" },
  { "output", "value" },
}

local function merge_results(old, new)
  if not old or old == "" then
    return new
  end
  local kept = {}
  for w in old:gmatch("%S+") do
    kept[#kept + 1] = w
  end
  for w in new:gmatch("%S+") do
    for _, group in ipairs(RESULTS_GROUPS) do
      if vim.tbl_contains(group, w) then
        kept = vim.tbl_filter(function(k)
          return not vim.tbl_contains(group, k)
        end, kept)
      end
    end
    if not vim.tbl_contains(kept, w) then
      kept[#kept + 1] = w
    end
  end
  return table.concat(kept, " ")
end

local function new_args()
  return { vars = {}, var_order = {} }
end

-- Merge a ":k1 v1 :k2 v2" header-argument string into `args`; later values
-- win, except :results which merges by exclusive group and :var by name.
local function apply_args(args, rest)
  if not rest or rest == "" then
    return args
  end
  local chunks = split_header_args(rest)
  for idx = 2, #chunks do
    local chunk = chunks[idx]:gsub("%s+$", "")
    local key, val = chunk:match("^(%S+)%s+(.*)$")
    if not key then
      key, val = chunk, ""
    end
    if key == "var" then
      local k, v = val:match("^([^=%s]+)%s*=%s*(.*)$")
      if k then
        if args.vars[k] == nil then
          args.var_order[#args.var_order + 1] = k
        end
        args.vars[k] = unquote(v)
      end
    elseif key == "results" then
      args.results = merge_results(args.results, unquote(val))
    elseif key ~= "" then
      args[key] = unquote(val)
    end
  end
  return args
end

-- Parse a "#+BEGIN_SRC LANG :k1 v1 :k2 v2" header line.
--
-- Vars (`:var k=v`) accumulate into a table; other keys are scalars.
function M.parse_header(line)
  local lang = line:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)") or ""
  local rest = line:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+%S+%s*(.*)$") or ""
  return lang, apply_args(new_args(), rest)
end

-- Block types whose contents org does not parse, so a #+begin_src inside
-- one is documentation, not code. Quote/center/special blocks DO nest.
local OPAQUE_BLOCKS = { example = true, export = true, verse = true, comment = true }

local function heading_level(l)
  local stars = l:match("^(%*+)%s") or l:match("^(%*+)$")
  return stars and #stars or nil
end

local function heading_commented(l)
  local rest = l:match("^%*+%s+(.*)$")
  if not rest then
    return false
  end
  local function leads(s)
    return s == "COMMENT" or s:match("^COMMENT%s") ~= nil
  end
  -- COMMENT may follow a TODO keyword and/or a priority cookie.
  return leads(rest) or leads((rest:gsub("^%u[%u%d_@%.]*%s+", "", 1):gsub("^%[#%a%]%s+", "", 1)))
end

-- Nearest-wins property lookup: file-level #+PROPERTY: first, then each
-- enclosing subtree from the outside in. A "<key>+" entry appends instead
-- of replacing (org-entry-get with inheritance).
local function property_value(key, file_props, stack)
  local val = file_props[key]
  if file_props[key .. "+"] then
    val = (val and val .. " " or "") .. file_props[key .. "+"]
  end
  for n = 1, #stack do
    local p = stack[n].props
    if p[key] then
      val = p[key]
    end
    if p[key .. "+"] then
      val = (val and val .. " " or "") .. p[key .. "+"]
    end
  end
  return val
end

-- Walk the buffer once, honouring container structure, and return every
-- src block with its fully resolved header arguments.
--
-- Fields: lang, args, name, header_line, end_line, body_lines, commented
-- (inside a COMMENT subtree), indent (of the #+begin_src line).
local function scan(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file_props, stack, blocks = {}, {}, {}
  local pending_name, pending_headers = nil, {}
  local function reset_affiliated()
    pending_name, pending_headers = nil, {}
  end
  local i = 1
  while i <= #lines do
    local l = lines[i] or ""
    local lvl = heading_level(l)
    local block_kind = l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
    if lvl then
      while #stack > 0 and stack[#stack].level >= lvl do
        table.remove(stack)
      end
      local parent = stack[#stack]
      stack[#stack + 1] = {
        level = lvl,
        props = {},
        title = (l:match("^%*+%s+(.-)%s*$") or ""),
        src_count = 0,
        commented = (parent and parent.commented) or heading_commented(l),
      }
      reset_affiliated()
    elseif l:lower():match("^%s*:properties:%s*$") then
      local node = stack[#stack]
      local j = i + 1
      while j <= #lines and not (lines[j] or ""):lower():match("^%s*:end:%s*$") do
        local k, v = (lines[j] or ""):match("^%s*:(%S+):%s*(.*)$")
        if k and node then
          node.props[k:lower()] = (v or ""):gsub("%s+$", "")
        end
        j = j + 1
      end
      i = j
      reset_affiliated()
    elseif l:match("^%s*#%+[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Yy]:") then
      local k, v = l:match("^%s*#%+[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Yy]:%s*(%S+)%s*(.*)$")
      if k then
        file_props[k:lower()] = (v or ""):gsub("%s+$", "")
      end
      reset_affiliated()
    elseif block_kind then
      local kind = block_kind:lower()
      local close = "^%s*#%+end_" .. vim.pesc(kind) .. "%s*$"
      local last
      for j = i + 1, #lines do
        if (lines[j] or ""):lower():match(close) then
          last = j
          break
        end
      end
      -- An unclosed #+begin_ is a paragraph to org, not a block.
      if kind == "src" and last then
        local lang = l:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)") or ""
        local args = new_args()
        apply_args(args, property_value("header-args", file_props, stack))
        if lang ~= "" then
          apply_args(args, property_value("header-args:" .. lang:lower(), file_props, stack))
        end
        apply_args(args, l:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+%S+%s*(.*)$") or "")
        for _, h in ipairs(pending_headers) do
          apply_args(args, h)
        end
        local body = {}
        for j = i + 1, last - 1 do
          body[#body + 1] = lines[j]
        end
        local node = stack[#stack]
        if node then
          node.src_count = node.src_count + 1
        end
        blocks[#blocks + 1] = {
          index = #blocks + 1,
          lang = lang,
          args = args,
          name = pending_name or (args.name ~= "" and args.name or nil),
          header_line = i,
          end_line = last,
          body_lines = body,
          commented = (node and node.commented) or false,
          heading = node and node.title or nil,
          heading_index = node and node.src_count or nil,
          indent = l:match("^%s*"),
        }
      end
      if last and (kind == "src" or OPAQUE_BLOCKS[kind]) then
        i = last
      end
      reset_affiliated()
    elseif l:match("^%s*#%+[Nn][Aa][Mm][Ee]:") then
      pending_name = (l:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$") or ""):gsub("%s+$", "")
      if pending_name == "" then
        pending_name = nil
      end
    elseif l:match("^%s*#%+[Hh][Ee][Aa][Dd][Ee][Rr][Ss]?:") then
      pending_headers[#pending_headers + 1] =
        l:match("^%s*#%+[Hh][Ee][Aa][Dd][Ee][Rr][Ss]?:%s*(.*)$")
    elseif not l:match("^%s*#%+%a") then
      reset_affiliated()
    end
    i = i + 1
  end
  return blocks
end

-- Cached per (bufnr, changedtick): execute_buffer walks every block, and
-- rescanning the whole buffer for each of them is the difference between
-- one scan per edit and one per block.
local _scan_cache = {}
local _scan_cached = 0

-- Every src block in `bufnr`, in document order.
function M.blocks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local hit = _scan_cache[bufnr]
  if hit and hit.tick == tick then
    return hit.blocks
  end
  if not hit then
    if _scan_cached >= 32 then
      for b in pairs(_scan_cache) do
        if not vim.api.nvim_buf_is_valid(b) then
          _scan_cache[b] = nil
          _scan_cached = _scan_cached - 1
        end
      end
    end
    _scan_cached = _scan_cached + 1
  end
  local blocks = scan(bufnr)
  _scan_cache[bufnr] = { tick = tick, blocks = blocks }
  return blocks
end

-- Find the src block enclosing `line` in bufnr. Returns:
--   { lang, name, args, header_line = N, end_line = N, body_lines = {...} }
-- or nil when the line is outside every block, or inside one whose contents
-- org treats as text (#+BEGIN_EXAMPLE and friends).
function M.find_block(bufnr, line)
  for _, b in ipairs(M.blocks(bufnr)) do
    if line >= b.header_line and line <= b.end_line then
      return b
    end
  end
  return nil
end

local function is_results_header(l)
  l = l:lower()
  return l:match("^%s*#%+results:") ~= nil or l:match("^%s*#%+results%b[]:") ~= nil
end

local function is_list_item(l)
  return l:match("^%s*[-+]%s") ~= nil
    or l:match("^%s+%*%s") ~= nil
    or l:match("^%s*%d+[.)]%s") ~= nil
end

-- Last line of the results element starting at lines[i], following
-- org-babel-result-end: only drawers, blocks, fixed-width, tables, lists,
-- latex environments, and a lone link count; anything else means the
-- header has no body.
local function results_body_end(lines, i)
  local l = lines[i] or ""
  if l:match("^%s*$") then
    return i - 1
  end
  local block = l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
  if block then
    local close = "^%s*#%+end_" .. vim.pesc(block:lower())
    for j = i + 1, #lines do
      if lines[j]:lower():match(close) then
        return j
      end
    end
    return #lines
  end
  if l:match("^%s*:[%w_%-]+:%s*$") then
    for j = i + 1, #lines do
      if lines[j]:lower():match("^%s*:end:%s*$") then
        return j
      end
    end
    return #lines
  end
  if l:match("^%s*\\begin{") then
    for j = i + 1, #lines do
      if lines[j]:match("^%s*\\end{") then
        return j
      end
    end
    return #lines
  end
  if l:match("^%s*%[%[.-%]%]%s*$") then
    return i
  end
  local function extend(pred)
    local j = i
    while j < #lines and pred(lines[j + 1]) do
      j = j + 1
    end
    return j
  end
  if l:match("^%s*:%s") or l:match("^%s*:$") then
    return extend(function(x)
      return x:match("^%s*:%s") or x:match("^%s*:$")
    end)
  end
  if l:match("^%s*|") then
    return extend(function(x)
      return x:match("^%s*|") or x:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:")
    end)
  end
  if is_list_item(l) then
    local indent = #l:match("^%s*")
    local j = i
    while j < #lines do
      local nxt = lines[j + 1]
      if nxt:match("^%s*$") then
        local after = lines[j + 2] or ""
        local deeper = #after:match("^%s*") > indent
        if after:match("^%s*$") or not (deeper or is_list_item(after)) then
          break
        end
      elseif not (is_list_item(nxt) or #nxt:match("^%s*") > indent) then
        break
      end
      j = j + 1
    end
    return j
  end
  return i - 1
end

-- Find an existing #+RESULTS: block for a block ending at `end_line`.
--
-- A named block owns `#+RESULTS: <name>` wherever it sits in the buffer
-- (org-babel-find-named-result); an anonymous one owns only the keyword
-- immediately below it. Returns (start, end) covering the whole results
-- element, or nil.
function M.find_results(bufnr, end_line, name)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if name and name ~= "" then
    local want = name:lower()
    for i, l in ipairs(lines) do
      local label = l:lower():match("^%s*#%+results:%s*(.-)%s*$")
        or l:lower():match("^%s*#%+results%b[]:%s*(.-)%s*$")
      if label == want then
        return i, results_body_end(lines, i + 1)
      end
    end
    return nil
  end
  local i = end_line + 1
  while i <= #lines and (lines[i] or ""):match("^%s*$") do
    i = i + 1
  end
  if not is_results_header(lines[i] or "") then
    return nil
  end
  return i, results_body_end(lines, i + 1)
end

local function results_params(args)
  local set = {}
  for w in (args.results or ""):gmatch("%S+") do
    set[w] = true
  end
  return set
end

local function split_output(stdout)
  local body_lines = vim.split(stdout or "", "\n", { plain = true })
  if body_lines[#body_lines] == "" then
    body_lines[#body_lines] = nil
  end
  return body_lines
end

local function examplify(body_lines)
  if #body_lines < 10 then
    local out = {}
    for i, l in ipairs(body_lines) do
      out[i] = ": " .. l
    end
    return out
  end
  local out = { "#+begin_example" }
  for _, l in ipairs(body_lines) do
    l = l:gsub("^(%s*,*)(%*)", "%1,%2"):gsub("^(%s*,*)(#%+)", "%1,%2")
    out[#out + 1] = l
  end
  out[#out + 1] = "#+end_example"
  return out
end

local function wrapped(body_lines, open, close)
  local out = { open }
  vim.list_extend(out, body_lines)
  out[#out + 1] = close
  return out
end

-- Format captured output into results body lines, following the value
-- groups of org-babel-insert-result.
local function format_results(stdout, params, lang, wrap_arg)
  local body_lines = split_output(stdout)
  if #body_lines == 0 then
    return {}
  end
  if params.file then
    local path = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return { "[[file:" .. path .. "]]" }
  end
  local tabular = false
  if params.list then
    for i, l in ipairs(body_lines) do
      body_lines[i] = "- " .. l
    end
  elseif (params.table or params.vector) and #body_lines > 1 then
    -- Emacs collapses a single-row import back to a scalar, so one line of
    -- output under :results table stays one line.
    for i, l in ipairs(body_lines) do
      local cells = {}
      if l:find("\t", 1, true) then
        for cell in (l .. "\t"):gmatch("(.-)\t") do
          cells[#cells + 1] = cell
        end
      else
        for cell in l:gmatch("%S+") do
          cells[#cells + 1] = cell
        end
      end
      body_lines[i] = "| " .. table.concat(cells, " | ") .. " |"
    end
    tabular = true
  end
  if wrap_arg and wrap_arg ~= "" then
    local type_ = wrap_arg:match("^%S+")
    if type_:lower() == "no" or type_:lower() == "nil" then
      return body_lines
    end
    return wrapped(body_lines, "#+begin_" .. wrap_arg, "#+end_" .. type_)
  end
  if params.html then
    return wrapped(body_lines, "#+begin_export html", "#+end_export")
  end
  if params.latex then
    return wrapped(body_lines, "#+begin_export latex", "#+end_export")
  end
  if params.org then
    return wrapped(body_lines, "#+begin_src org", "#+end_src")
  end
  if params.code then
    return wrapped(body_lines, "#+begin_src " .. (lang ~= "" and lang or "none"), "#+end_src")
  end
  if params.raw then
    return body_lines
  end
  if params.drawer or params.wrap then
    return wrapped(body_lines, ":results:", ":end:")
  end
  if tabular then
    return body_lines
  end
  return examplify(body_lines)
end

local function get_cfg(bufnr)
  return require("organ.buf_config").read(bufnr, "babel") or {}
end

-- The confirmation gate is keyed to the buffer whose block is running, not
-- to whatever buffer happens to be current when a command reaches here.
local function confirm_run(bufnr, lang, body)
  local cfg = get_cfg(bufnr)
  if cfg.confirm_evaluate == false then
    return true
  end
  local allow = cfg.allow_languages or {}
  for _, l in ipairs(allow) do
    if l == lang then
      return true
    end
  end
  local preview = body:sub(1, 200)
  local prompt = ("Evaluate %s block? (Y/n)\n%s"):format(lang, preview)
  local ans = vim.fn.confirm(prompt, "&Yes\n&No", 2)
  return ans == 1
end

-- Every block reachable by name: #+NAME: keyword or organ's own `:name`
-- header argument.
local function named_blocks(bufnr)
  local named = {}
  for _, b in ipairs(M.blocks(bufnr)) do
    if b.name and not named[b.name] then
      named[b.name] = b
    end
  end
  return named
end

-- Strip the deepest common indentation, as org-babel--normalize-body does
-- before handing a body to a runner or to tangle.
local function dedent(body_lines)
  local common
  for _, l in ipairs(body_lines) do
    if not l:match("^%s*$") then
      local n = #(l:match("^[ \t]*"))
      common = (common == nil or n < common) and n or common
    end
  end
  if not common or common == 0 then
    return body_lines
  end
  local out = {}
  for i, l in ipairs(body_lines) do
    out[i] = l:sub(common + 1)
  end
  return out
end

local NOWEB_MAX_DEPTH = 64

-- Expand <<name>> references against `named`. A reference alone on its line
-- keeps that line's indentation on every expanded line; references inside a
-- line are substituted in place. Unlike Emacs, a cycle stops at the repeated
-- reference and leaves it literal instead of recursing until the stack dies.
local function expand_noweb(body_lines, named, active, depth)
  active = active or {}
  depth = depth or 0
  local function resolve(name)
    if depth >= NOWEB_MAX_DEPTH or active[name] then
      return nil
    end
    local target = named[name]
    if not target then
      return nil
    end
    active[name] = true
    local expanded = expand_noweb(dedent(target.body_lines), named, active, depth + 1)
    active[name] = nil
    return expanded
  end
  local out = {}
  for _, line in ipairs(body_lines) do
    local indent, ref = line:match("^([ \t]*)<<([^<>]-)>>[ \t]*$")
    local resolved = ref and resolve((ref:gsub("%b()$", "")))
    if resolved then
      for _, rl in ipairs(resolved) do
        out[#out + 1] = indent .. rl
      end
    elseif line:find("<<", 1, true) then
      local replaced = line:gsub("<<([^<>]-)>>", function(name)
        local r = resolve((name:gsub("%b()$", "")))
        return r and table.concat(r, "\n") or nil
      end)
      vim.list_extend(out, vim.split(replaced, "\n", { plain = true }))
    else
      out[#out + 1] = line
    end
  end
  return out
end

local function noweb_wanted(noweb, context)
  local allowed = context == "tangle"
      and { yes = true, tangle = true, ["no-export"] = true, ["strip-export"] = true }
    or { yes = true, ["no-export"] = true, ["strip-export"] = true, eval = true }
  for w in (noweb or ""):gmatch("%S+") do
    if allowed[w] then
      return true
    end
  end
  return false
end

-- Read back a `#+RESULTS:` element as a plain value: `: x` lines and
-- example blocks lose their markup, everything else comes through as text.
local function results_text(bufnr, rs, re)
  local lines = vim.api.nvim_buf_get_lines(bufnr, rs, re, false)
  if lines[1] and lines[1]:lower():match("^%s*#%+begin_example") then
    table.remove(lines, 1)
    if lines[#lines] and lines[#lines]:lower():match("^%s*#%+end_example") then
      table.remove(lines)
    end
  elseif lines[1] and lines[1]:match("^%s*:results:%s*$") then
    table.remove(lines, 1)
    if lines[#lines] and lines[#lines]:lower():match("^%s*:end:%s*$") then
      table.remove(lines)
    end
  else
    for i, l in ipairs(lines) do
      lines[i] = l:gsub("^%s*:%s?", "", 1)
    end
  end
  return table.concat(lines, "\n")
end

-- Per-language `:var` bindings. Shells get the values through the
-- environment (opts.vars); languages that cannot see them get assignment
-- statements prepended to the body, as org-babel-variable-assignments does.
local function quoted(v)
  local s = tostring(v)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
  return '"' .. s .. '"'
end

M.var_assignments = {
  python = function(name, value)
    return name .. " = " .. quoted(value)
  end,
  lua = function(name, value)
    return name .. " = " .. quoted(value)
  end,
  javascript = function(name, value)
    return "var " .. name .. " = " .. quoted(value) .. ";"
  end,
  ruby = function(name, value)
    return name .. " = " .. quoted(value)
  end,
  perl = function(name, value)
    return "my $" .. name .. " = " .. quoted(value) .. ";"
  end,
  R = function(name, value)
    return name .. " <- " .. quoted(value)
  end,
}
M.var_assignments.js = M.var_assignments.javascript
M.var_assignments.r = M.var_assignments.R

-- `:results value` rewrites the body so that what the block RETURNS is what
-- lands in #+RESULTS:, the way ob-python's wrapper method does.  A language
-- with no entry here collects its output instead, which is organ's default
-- for every block and the more useful answer for the shells (Emacs returns
-- the exit status there).
M.value_collectors = {
  python = function(body)
    local out = { "def __organ_value():", "    pass" }
    for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
      out[#out + 1] = "    " .. l
    end
    -- What the body prints is not its value, so it must not reach the result.
    vim.list_extend(out, {
      "import io as __organ_io, contextlib as __organ_ctx, sys as __organ_sys",
      "__organ_sink = __organ_io.StringIO()",
      "with __organ_ctx.redirect_stdout(__organ_sink):",
      "    __organ_out = __organ_value()",
      '__organ_sys.stdout.write(str(__organ_out) + "\\n")',
    })
    return table.concat(out, "\n")
  end,
}

-- Bind `:var NAME=VALUE`. A value naming another block in the buffer is
-- replaced by that block's result (org-babel-ref-resolve): its existing
-- #+RESULTS:, or a fresh run of it. A value naming nothing stays the
-- literal string organ has always bound, where Emacs raises an error.
local function resolve_vars(bufnr, block, state)
  local vars = {}
  for name, value in pairs(block.args.vars or {}) do
    vars[name] = value
  end
  if not next(vars) then
    return vars
  end
  local named = named_blocks(bufnr)
  for name, value in pairs(vars) do
    local target = named[value]
    if target and target.header_line ~= block.header_line and not state.names[value] then
      local rs, re = M.find_results(bufnr, target.end_line, target.name)
      if not rs then
        state.names[value] = true
        M.execute(bufnr, target.header_line, state)
        state.names[value] = nil
        state.rescan = true
        rs, re = M.find_results(bufnr, target.end_line, target.name)
      end
      if rs and re and re >= rs then
        vars[name] = results_text(bufnr, rs, re)
      end
    end
  end
  return vars
end

-- Cache key for `:cache yes`: any change to the body or the header
-- arguments must miss (org-babel-sha1-hash).
local function cache_hash(block, body)
  local keys = {}
  for k, v in pairs(block.args) do
    if k ~= "vars" and k ~= "var_order" and type(v) == "string" then
      keys[#keys + 1] = k .. "=" .. v
    end
  end
  for k, v in pairs(block.args.vars or {}) do
    keys[#keys + 1] = "var " .. k .. "=" .. tostring(v)
  end
  table.sort(keys)
  return vim.fn.sha256(body .. "\0" .. table.concat(keys, "\0")):sub(1, 40)
end

-- Execute the src block at cursor; insert / update its #+RESULTS:.
-- Returns (ok, msg).
function M.execute(bufnr, line, state, block)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  state = state or { names = {} }
  block = block or M.find_block(bufnr, line)
  if not block then
    return false, "no src block at cursor"
  end
  if block.args.eval == "no" or block.args.eval == "never" then
    return false, "block is :eval no"
  end
  local body_lines = dedent(block.body_lines)
  if noweb_wanted(block.args.noweb, "eval") then
    body_lines = expand_noweb(body_lines, named_blocks(bufnr))
  end
  local body = table.concat(body_lines, "\n")
  if not confirm_run(bufnr, block.lang, body) then
    return false, "evaluation declined"
  end

  local params = results_params(block.args)
  local msg = "ran " .. block.lang .. " block (" .. #block.body_lines .. " lines)"
  local hash = block.args.cache == "yes" and cache_hash(block, body) or nil
  if hash then
    local cached = M.find_results(bufnr, block.end_line, block.name)
    local existing = cached and vim.api.nvim_buf_get_lines(bufnr, cached - 1, cached, false)[1]
    if existing and existing:lower():match("^%s*#%+results%[" .. hash:lower() .. "%]") then
      return true, "cached " .. block.lang .. " block"
    end
  end

  local vars = resolve_vars(bufnr, block, state)
  if state.rescan then
    -- Running a referenced block inserted its results, which shifts our line
    -- numbers; the src-block ordinal survives that, so re-fetch by it.
    block = M.blocks(bufnr)[block.index] or block
  end
  local rs, re = M.find_results(bufnr, block.end_line, block.name)
  local assign = M.var_assignments[block.lang]
  if assign then
    local prologue = {}
    for name, value in pairs(vars) do
      prologue[#prologue + 1] = assign(name, value)
    end
    table.sort(prologue)
    if #prologue > 0 then
      body = table.concat(prologue, "\n") .. "\n" .. body
    end
  end
  if params.value and M.value_collectors[block.lang] then
    body = M.value_collectors[block.lang](body)
  end

  local stdout, stderr, rc
  local timeout_ms = tonumber(get_cfg(bufnr).timeout_ms) or M.DEFAULT_TIMEOUT_MS

  -- :session header -> use the persistent-interpreter path so variables
  -- and imports carry between blocks (Emacs literate-programming workflow).
  if block.args.session and block.args.session ~= "" and block.args.session ~= "none" then
    local sessions_ok, sessions = pcall(require, "organ.babel.sessions")
    if sessions_ok then
      sessions._install_autocmd()
      local out, err = sessions.eval(block.lang, block.args.session, body, timeout_ms)
      if out ~= nil then
        stdout, stderr, rc = out, "", 0
      else
        stdout, stderr, rc = "", err or "session eval failed", 1
      end
    else
      stdout, stderr, rc = "", "session module unavailable: " .. tostring(sessions), 1
    end
  else
    local runner = M.languages[block.lang]
    if not runner then
      return false, "no runner registered for language: " .. block.lang
    end
    stdout, stderr, rc = runner(body, {
      vars = vars,
      dir = block.args.dir,
      timeout_ms = timeout_ms,
    })
  end
  if rc ~= 0 and stderr and stderr ~= "" then
    -- Surface the error inline instead of failing silently.
    stdout = (stdout ~= "" and stdout .. "\n" or "") .. "STDERR: " .. stderr
  end

  if params.silent or params.none or params.discard then
    return true, msg .. ": " .. stdout
  end
  -- `:results file :file PATH` writes the output to PATH and links to it.
  if params.file and block.args.file and block.args.file ~= "" then
    local target = block.args.file
    local path = target
    if not path:match("^[/~]") then
      local base = block.args["output-dir"] or vim.api.nvim_buf_get_name(bufnr)
      base = base ~= "" and vim.fn.fnamemodify(base, ":h") or vim.fn.getcwd()
      path = base .. "/" .. path
    end
    local written, werr = require("organ.path").write_atomic(vim.fn.expand(path), stdout .. "\n")
    if not written then
      return false, "could not write :file " .. target .. ": " .. tostring(werr)
    end
    stdout = target
  end
  local body_out = format_results(stdout, params, block.lang, block.args.wrap)
  local keyword = "#+RESULTS"
    .. (hash and ("[" .. hash .. "]") or "")
    .. ":"
    .. (block.name and (" " .. block.name) or "")
  if rs and re then
    local header = vim.api.nvim_buf_get_lines(bufnr, rs - 1, rs, false)[1]
    if hash then
      header = keyword
    end
    local old = re >= rs and vim.api.nvim_buf_get_lines(bufnr, rs, re, false) or {}
    local merged = { header }
    if params.append then
      vim.list_extend(merged, old)
      vim.list_extend(merged, body_out)
    elseif params.prepend then
      vim.list_extend(merged, body_out)
      vim.list_extend(merged, old)
    else
      vim.list_extend(merged, body_out)
    end
    obuf.set_lines(bufnr, rs - 1, math.max(re, rs), merged)
  else
    obuf.set_lines(
      bufnr,
      block.end_line,
      block.end_line,
      vim.list_extend({ "", keyword }, body_out)
    )
  end
  return true, msg
end

-- Execute every src block in the buffer.
function M.execute_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local count, errors = 0, {}
  -- Iterate from bottom up so insertions don't shift the lines we've yet to
  -- visit, which also means one scan serves the whole run.  A block that had
  -- to run a `:var` reference sets state.rescan; only then is the scan redone.
  local blocks = M.blocks(bufnr)
  local state = { names = {} }
  for i = #blocks, 1, -1 do
    if state.rescan then
      blocks = M.blocks(bufnr)
      state.rescan = nil
    end
    -- One block's failure must not abandon the blocks below it half-run.
    local ok, done, why = pcall(M.execute, bufnr, nil, state, blocks[i])
    if not ok then
      errors[#errors + 1] = tostring(done)
    elseif done then
      count = count + 1
    else
      errors[#errors + 1] = tostring(why)
    end
  end
  return count, errors
end

-- Tangle every block with a :tangle FILE arg. Each destination gets a
-- concatenation of all blocks with that target.
--
-- Header args honoured beyond the basic :tangle FILE:
--   :noweb yes|tangle|no-export|strip-export   expand <<name>> references
--   :mkdirp yes    create parent directories for the destination file
--   :shebang LINE  first line of the file; the file is made executable
--   :comments link|yes|both|org|noweb          wrap blocks in link comments
--   :padline no    do not separate blocks with a blank line
--
-- org-babel-tangle-lang-exts, including the entries the ob-* modules add.
local TANGLE_EXTS = {
  ["emacs-lisp"] = "el",
  elisp = "el",
  bibtex = "bib",
  awk = "awk",
  clojure = "clj",
  clojurescript = "cljs",
  ["C++"] = "cpp",
  D = "d",
  csharp = "cs",
  fortran = "F90",
  groovy = "groovy",
  haskell = "hs",
  java = "java",
  julia = "jl",
  latex = "tex",
  LilyPond = "ly",
  lisp = "lisp",
  lua = "lua",
  maxima = "max",
  ocaml = "ml",
  perl = "pl",
  processing = "pde",
  python = "py",
  ruby = "rb",
  sed = "sed",
}

-- Line-comment syntax per language, for :comments link.
local COMMENT_PREFIX = {
  sh = "#",
  bash = "#",
  zsh = "#",
  fish = "#",
  python = "#",
  ruby = "#",
  perl = "#",
  R = "#",
  r = "#",
  awk = "#",
  julia = "#",
  elixir = "#",
  lua = "--",
  haskell = "--",
  sql = "--",
  sqlite = "--",
  lisp = ";",
  scheme = ";",
  clojure = ";",
  ["emacs-lisp"] = ";",
  elisp = ";",
  latex = "%",
}

-- Absolute path with `.`, `..` and symlinks resolved, so two spellings of
-- one file compare equal.  A destination that does not exist yet resolves
-- through its parent directory.
local function real_path(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  local resolved = vim.uv.fs_realpath(abs)
  if resolved then
    return resolved
  end
  local dir = vim.uv.fs_realpath(vim.fn.fnamemodify(abs, ":h"))
  if dir then
    return dir .. "/" .. vim.fn.fnamemodify(abs, ":t")
  end
  return vim.fs.normalize(abs)
end

local SELF_TANGLE = "Not allowed to tangle into the same file as self"

-- Returns { path = { ok = bool, blocks = N, error = ... } }.
function M.tangle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local source_path = vim.api.nvim_buf_get_name(bufnr)
  local source_dir = source_path ~= "" and vim.fn.fnamemodify(source_path, ":h") or vim.fn.getcwd()
  local source_name = source_path ~= "" and vim.fn.fnamemodify(source_path, ":t") or "buffer"
  local blocks = M.blocks(bufnr)
  local named = named_blocks(bufnr)

  local groups = {} -- absolute_path -> { lines... }
  local mkdirp = {} -- absolute_path -> bool
  local shebangs = {} -- absolute_path -> shebang line
  local results = {}

  for _, block in ipairs(blocks) do
    local args = block.args
    local tangle = args.tangle
    -- Emacs excludes COMMENT subtrees from tangling (but still evaluates
    -- their blocks on request).
    if block.commented then
      tangle = nil
    end
    if tangle == "yes" or tangle == "tangle" then
      if source_path == "" then
        results.yes = { ok = false, error = ":tangle yes needs a file-backed buffer" }
        tangle = nil
      else
        tangle = vim.fn.fnamemodify(source_path, ":p:r")
          .. "."
          .. (TANGLE_EXTS[block.lang] or block.lang)
      end
    end
    if tangle and tangle ~= "no" and tangle ~= "" then
      if tangle:sub(1, 1) == "~" then
        tangle = vim.fn.fnamemodify(tangle, ":p")
      elseif tangle:sub(1, 1) ~= "/" then
        tangle = source_dir .. "/" .. tangle
      end
      local body = dedent(block.body_lines)
      if noweb_wanted(args.noweb, "tangle") then
        body = expand_noweb(body, named)
      end
      if args.mkdirp == "yes" then
        mkdirp[tangle] = true
      end
      if args.shebang and args.shebang ~= "" and not shebangs[tangle] then
        shebangs[tangle] = args.shebang
      end
      local out = groups[tangle] or {}
      local comments = args.comments
      local link
      if comments and comments ~= "" and comments ~= "no" then
        local prefix = COMMENT_PREFIX[block.lang] or "//"
        local target, label
        if block.name then
          target, label = block.name, block.name
        else
          local heading = block.heading or ""
          target = "*" .. heading
          label = heading .. ":" .. tostring(block.heading_index or 1)
        end
        link = {
          open = ("%s [[file:%s::%s][%s]]"):format(prefix, source_name, target, label),
          close = ("%s %s ends here"):format(prefix, label),
        }
      end
      if #out > 0 and args.padline ~= "no" then
        out[#out + 1] = ""
      end
      if link then
        out[#out + 1] = link.open
      end
      vim.list_extend(out, body)
      if link then
        out[#out + 1] = link.close
      end
      groups[tangle] = out
    end
  end

  local source_real = source_path ~= "" and real_path(source_path) or nil
  for path, body in pairs(groups) do
    if source_real and real_path(path) == source_real then
      results[path] = { ok = false, error = SELF_TANGLE }
    else
      if mkdirp[path] then
        pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
      end
      local text = table.concat(body, "\n") .. "\n"
      if shebangs[path] then
        text = shebangs[path] .. "\n" .. text
      end
      local ok, err = require("organ.path").write_atomic(path, text)
      if ok then
        if shebangs[path] then
          pcall(vim.uv.fs_chmod, path, tonumber("755", 8))
        end
        results[path] = { ok = true, blocks = #body }
      else
        results[path] = { ok = false, error = err }
      end
    end
  end
  return results
end

M.commands = {
  ["babel execute"] = {
    fn = function()
      local ok, msg = M.execute()
      if not ok then
        require("organ.notify").warn(tostring(msg))
      else
        require("organ.notify").info(tostring(msg))
      end
    end,
    desc = "Execute the #+BEGIN_SRC block at cursor and insert/update its #+RESULTS:",
  },
  ["babel execute_buffer"] = {
    fn = function()
      local count, errors = M.execute_buffer()
      require("organ.notify").info(("ran %d block(s); %d error(s)"):format(count, #errors))
      for _, e in ipairs(errors) do
        require("organ.notify").warn(tostring(e))
      end
    end,
    desc = "Execute every #+BEGIN_SRC block in the current buffer",
  },
  ["babel tangle"] = {
    fn = function()
      local results = M.tangle()
      local n = 0
      for _ in pairs(results) do
        n = n + 1
      end
      require("organ.notify").info(("tangled to %d file(s)"):format(n))
      for path, r in pairs(results) do
        if r.ok then
          require("organ.notify").info("organ: wrote " .. path)
        else
          require("organ.notify").error(
            "organ: tangle failed " .. path .. ": " .. tostring(r.error)
          )
        end
      end
    end,
    desc = "Write each :tangle <file> src block to its destination file",
  },
}

return M
