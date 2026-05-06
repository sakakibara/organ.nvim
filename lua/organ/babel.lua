-- Org-Babel: execute #+BEGIN_SRC blocks and tangle them to files.
--
-- This is a focused subset of Emacs org-babel — enough for everyday
-- run-this-snippet workflows, not full feature parity.
--
-- Supported header args:
--   :results value | output        what to capture (default value=output for shell)
--   :results raw | replace         output formatting (default replace)
--   :exports code | results | both | none
--   :tangle <file>                 destination for :Org babel tangle
--   :var KEY=VALUE                 passed as env var KEY (subset; flat strings)
--   :dir <dir>                     run in this working directory
--
-- Built-in languages: sh, bash, python, lua. Register more via M.languages.
--
-- Security: every execute prompts via vim.ui.input unless
-- config.babel.confirm_evaluate = false OR the language appears in
-- config.babel.allow_languages = { "sh", "python", ... }.

local M = {}

-- Per-language runner. Each runner takes (body, opts) where opts has
-- { vars = { KEY = "VAL" }, dir = "/abs/path" } and returns (stdout, stderr, exit_code).
M.languages = {}

local function run_subprocess(cmd, opts, body)
  local env = nil
  if opts.vars and next(opts.vars) then
    env = {}
    for k, v in pairs(vim.fn.environ()) do
      env[#env + 1] = k .. "=" .. v
    end
    for k, v in pairs(opts.vars) do
      env[#env + 1] = k .. "=" .. tostring(v)
    end
  end
  local out_lines = {}
  local err_lines = {}
  local job = vim.fn.jobstart(cmd, {
    cwd = opts.dir,
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
  })
  if job <= 0 then
    return "", "failed to start " .. table.concat(cmd, " "), -1
  end
  if body and body ~= "" then
    vim.fn.chansend(job, body)
    vim.fn.chanclose(job, "stdin")
  end
  local rc = vim.fn.jobwait({ job }, 60000)[1]
  -- Strip trailing empty line that nvim adds.
  if out_lines[#out_lines] == "" then
    out_lines[#out_lines] = nil
  end
  if err_lines[#err_lines] == "" then
    err_lines[#err_lines] = nil
  end
  return table.concat(out_lines, "\n"), table.concat(err_lines, "\n"), rc
end

-- ---------------------------------------------------------------------------
-- Built-in language runners.
--
-- Each runner takes `body` (string) + `opts` ({ vars, dir }), spawns a
-- subprocess, pipes the body to stdin where appropriate, captures stdout +
-- stderr + rc, and returns (stdout, stderr, rc).
--
-- Runners that need a temp file (compiled languages — c/cpp/rust/go/java)
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

-- SQL — pipe body to sqlite3. Database is :memory: by default; users can
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

-- Parse a "#+BEGIN_SRC LANG :k1 v1 :k2 v2" header line.
--
-- Vars (`:var k=v`) accumulate into a table; other keys are scalars.
function M.parse_header(line)
  local lang = line:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)") or ""
  local args = { vars = {} }
  -- Strip up through the language token so we only iterate true header args.
  local rest = line:match("[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+%S+%s*(.*)$") or ""
  -- Split into ":key value [value...]" runs.
  for key, val in rest:gmatch(":(%S+)%s+([^:]*)") do
    val = val:gsub("%s+$", "")
    if key == "var" then
      local k, v = val:match("^([%w_]+)=(.*)$")
      if k then
        args.vars[k] = v
      end
    else
      args[key] = val
    end
  end
  return lang, args
end

-- Find the src block enclosing `line` in bufnr. Returns:
--   { lang, header, args, begin = N, end = N, body_lines = {...} }
-- or nil.
function M.find_block(bufnr, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Walk down: if `line` is past the matching #+begin_src and before #+end_src.
  -- Walk up first to find a possible begin.
  local begin
  for i = line, 1, -1 do
    local l = lines[i] or ""
    if l:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") then
      return nil
    end
    if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]") then
      begin = i
      break
    end
  end
  if not begin then
    return nil
  end
  local end_idx
  for i = begin + 1, #lines do
    if (lines[i] or ""):match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") then
      end_idx = i
      break
    end
  end
  if not end_idx then
    return nil
  end
  local lang, args = M.parse_header(lines[begin])
  local body = {}
  for i = begin + 1, end_idx - 1 do
    body[#body + 1] = lines[i]
  end
  return {
    lang = lang,
    header_line = begin,
    end_line = end_idx,
    args = args,
    body_lines = body,
  }
end

-- Find an existing #+RESULTS: block immediately following end_line; returns
-- (start, end) of the entire results block (including its `#+RESULTS:` header
-- and any wrapping :results or example block), or nil.
function M.find_results(bufnr, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local i = end_line + 1
  while i <= #lines and (lines[i] or ""):match("^%s*$") do
    i = i + 1
  end
  if not (lines[i] or ""):match("^%s*#%+RESULTS:") then
    return nil
  end
  local start = i
  i = i + 1
  -- Wrapped result: example/quote block, drawer, or single-line.
  local wrap = (lines[i] or ""):match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%a+)")
  if wrap then
    while i <= #lines do
      if (lines[i] or ""):lower():find("^%s*#%+end_" .. wrap:lower()) then
        return start, i
      end
      i = i + 1
    end
    return start, #lines
  end
  if (lines[i] or ""):match("^%s*:results:") then
    while i <= #lines and not (lines[i] or ""):match("^%s*:end:") do
      i = i + 1
    end
    return start, i
  end
  -- Single-line: collect contiguous `: ` indented results.
  while i <= #lines and (lines[i] or ""):match("^%s*:%s") do
    i = i + 1
  end
  return start, i - 1
end

-- Format captured stdout into a results block. Returns a list of lines.
local function format_results(stdout, args)
  local body_lines = vim.split(stdout or "", "\n", { plain = true })
  -- Drop a single trailing empty line that came from a final newline.
  if body_lines[#body_lines] == "" then
    body_lines[#body_lines] = nil
  end
  if args.results == "raw" then
    local out = { "#+RESULTS:" }
    for _, l in ipairs(body_lines) do
      out[#out + 1] = l
    end
    return out
  end
  -- Default: wrap in `: ` for short single-line; `#+begin_example` otherwise.
  if #body_lines <= 1 then
    return { "#+RESULTS:", ": " .. (body_lines[1] or "") }
  end
  local out = { "#+RESULTS:", "#+begin_example" }
  for _, l in ipairs(body_lines) do
    out[#out + 1] = l
  end
  out[#out + 1] = "#+end_example"
  return out
end

local function get_cfg()
  return (require("organ").config or {}).babel or {}
end

local function confirm_run(lang, body)
  local cfg = get_cfg()
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

-- Execute the src block at cursor; insert / update its #+RESULTS:.
-- Returns (ok, msg).
function M.execute(bufnr, line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local block = M.find_block(bufnr, line)
  if not block then
    return false, "no src block at cursor"
  end
  if block.args.eval == "no" or block.args.eval == "never" then
    return false, "block is :eval no"
  end
  local body = table.concat(block.body_lines, "\n")
  if not confirm_run(block.lang, body) then
    return false, "evaluation declined"
  end

  local stdout, stderr, rc

  -- :session header → use the persistent-interpreter path so variables
  -- and imports carry between blocks (Emacs literate-programming
  -- workflow). Falls back to a fresh subprocess when sessions don't
  -- support the language.
  if block.args.session and block.args.session ~= "" then
    local sessions_ok, sessions = pcall(require, "organ.babel.sessions")
    if sessions_ok then
      sessions._install_autocmd()
      local out, err = sessions.eval(block.lang, block.args.session, body)
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
      vars = block.args.vars,
      dir = block.args.dir,
    })
  end
  if rc ~= 0 and stderr and stderr ~= "" then
    -- Surface the error inline instead of failing silently.
    stdout = (stdout ~= "" and stdout .. "\n" or "") .. "STDERR: " .. stderr
  end

  local result_lines = format_results(stdout, block.args)
  local rs, re = M.find_results(bufnr, block.end_line)
  if rs and re then
    vim.api.nvim_buf_set_lines(bufnr, rs - 1, re, false, result_lines)
  else
    -- Insert just below #+end_src (with a blank line separator).
    vim.api.nvim_buf_set_lines(
      bufnr,
      block.end_line,
      block.end_line,
      false,
      vim.list_extend({ "" }, result_lines)
    )
  end
  return true, ("ran " .. block.lang .. " block (" .. #block.body_lines .. " lines)")
end

-- Execute every src block in the buffer.
function M.execute_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count, errors = 0, {}
  -- Iterate from bottom up so insertions don't shift indices we've yet to visit.
  local headers = {}
  for i, l in ipairs(lines) do
    if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]") then
      headers[#headers + 1] = i
    end
  end
  for i = #headers, 1, -1 do
    local ok, msg = M.execute(bufnr, headers[i])
    if ok then
      count = count + 1
    else
      errors[#errors + 1] = msg
    end
  end
  return count, errors
end

-- Tangle every block with a :tangle FILE arg. Each destination gets a
-- concatenation of all blocks with that target.
--
-- Supports two header args beyond the basic :tangle FILE:
--   :noweb yes     — expand <<name>> references inline from blocks
--                    that have a `:name NAME` header. Mirrors Emacs's
--                    `org-babel-tangle` noweb mode.
--   :mkdirp yes    — create parent directories for the destination
--                    file on tangle (Emacs default behaviour when on).
--
-- Returns { path = { ok = bool, blocks = N, error = ... } }.
function M.tangle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local source_path = vim.api.nvim_buf_get_name(bufnr)
  local source_dir = source_path ~= "" and vim.fn.fnamemodify(source_path, ":h") or vim.fn.getcwd()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- First pass: collect every named block's body so noweb references
  -- can resolve in the second pass.
  local named = {} -- block name → { body lines }
  do
    local j = 1
    while j <= #lines do
      if (lines[j] or ""):match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]") then
        local _, args = M.parse_header(lines[j])
        local body, k = {}, j + 1
        while k <= #lines and not (lines[k] or ""):match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") do
          body[#body + 1] = lines[k]
          k = k + 1
        end
        if args.name and args.name ~= "" then
          named[args.name] = body
        end
        j = k
      end
      j = j + 1
    end
  end

  local function expand_noweb(body)
    local out = {}
    for _, line in ipairs(body) do
      local ref = line:match("^%s*<<(.-)>>%s*$")
      if ref and named[ref] then
        for _, ref_line in ipairs(named[ref]) do
          out[#out + 1] = ref_line
        end
      else
        out[#out + 1] = line
      end
    end
    return out
  end

  local groups = {} -- absolute_path -> { lines... }
  local mkdirp = {} -- absolute_path -> bool

  local i = 1
  while i <= #lines do
    if (lines[i] or ""):match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]") then
      local _, args = M.parse_header(lines[i])
      local tangle = args.tangle
      if tangle and tangle ~= "no" and tangle ~= "" then
        if tangle:sub(1, 1) ~= "/" then
          tangle = source_dir .. "/" .. tangle
        end
        local body = {}
        local j = i + 1
        while j <= #lines and not (lines[j] or ""):match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") do
          body[#body + 1] = lines[j]
          j = j + 1
        end
        if args.noweb == "yes" or args.noweb == "tangle" then
          body = expand_noweb(body)
        end
        if args.mkdirp == "yes" then
          mkdirp[tangle] = true
        end
        groups[tangle] = groups[tangle] or {}
        for _, l in ipairs(body) do
          groups[tangle][#groups[tangle] + 1] = l
        end
        groups[tangle][#groups[tangle] + 1] = "" -- separator between blocks
        i = j
      end
    end
    i = i + 1
  end
  local results = {}
  for path, body in pairs(groups) do
    if mkdirp[path] then
      pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
    end
    local ok, err = require("organ.path").write_atomic(path, table.concat(body, "\n"))
    if ok then
      results[path] = { ok = true, blocks = #body }
    else
      results[path] = { ok = false, error = err }
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
