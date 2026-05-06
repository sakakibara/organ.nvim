-- Babel sessions: persistent interpreters per (language, session-name).
--
-- Without sessions, every `#+begin_src python` block runs in a fresh
-- process; variables and imports don't carry between blocks. With
-- `:session foo`, all blocks tagged `:session foo` share one long-
-- lived interpreter — the standard literate-programming workflow.
--
-- Supported languages (initial):
--   python  → `python3 -i -u`
--   sh / bash  → `bash -i`
--
-- Mechanism: spawn the interpreter via vim.uv.spawn, write the block's
-- body to its stdin followed by a unique sentinel that we then look
-- for in stdout. Output before the sentinel = the block's result.
--
-- Lifecycle: sessions live until the user calls
-- M.stop_session / M.stop_all, or until VimLeavePre fires.

local M = {}

-- Active sessions, keyed by "lang:name" (e.g. "python:foo").
M._sessions = M._sessions or {}

-- Seed the RNG once per session so the eval sentinel isn't the same
-- value on every nvim start. Defense-in-depth: a body that happens
-- to contain the sentinel string would falsely terminate the read,
-- so a per-session-unique sentinel is preferable to a deterministic
-- one. (`math.random(1, 1e9)` alone is enough to make collisions
-- effectively impossible; the seeding is just polish.)
do
  local ok = pcall(math.randomseed, vim.uv.hrtime())
  if not ok then
    pcall(math.randomseed, os.time())
  end
end

-- Default per-language settings. Override via config.babel.sessions.<lang>.
local LANGS = {
  python = {
    cmd = "python3",
    args = { "-i", "-u" },
    sentinel_fn = function(s)
      return "print('" .. s .. "')"
    end,
    -- Strip Python REPL prompts and the echoed sentinel-print line.
    clean = function(text)
      text = text:gsub("\r", "")
      -- Strip ">>> " and "... " at line starts.
      text = text:gsub("\n>>> ", "\n")
      text = text:gsub("\n%.%.%. ", "\n")
      text = text:gsub("^>>> ", "")
      text = text:gsub("^%.%.%. ", "")
      return text
    end,
  },
  sh = {
    cmd = "sh",
    args = { "-i" },
    sentinel_fn = function(s)
      return "echo '" .. s .. "'"
    end,
    clean = function(text)
      return (text:gsub("\r", ""))
    end,
  },
  bash = {
    cmd = "bash",
    args = { "-i" },
    sentinel_fn = function(s)
      return "echo '" .. s .. "'"
    end,
    clean = function(text)
      text = text:gsub("\r", "")
      -- Strip bash's "bash: no job control in this shell" if it leaks.
      text = text:gsub("bash: no job control in this shell\n", "")
      return text
    end,
  },
}

local function key(lang, name)
  return lang .. ":" .. (name or "default")
end

local function spawn(lang)
  local conf = LANGS[lang]
  if not conf then
    return nil, "unsupported session language: " .. lang
  end
  if vim.fn.executable(conf.cmd) ~= 1 then
    return nil, "executable not found: " .. conf.cmd
  end

  local stdin = vim.uv.new_pipe(false)
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)

  local s = {
    lang = lang,
    conf = conf,
    out = "",
    alive = true,
    stdin = stdin,
    stdout = stdout,
    stderr = stderr,
  }

  local handle, pid_or_err = vim.uv.spawn(conf.cmd, {
    args = conf.args,
    stdio = { stdin, stdout, stderr },
  }, function(_code, _signal)
    s.alive = false
  end)
  if not handle then
    pcall(function()
      stdin:close()
      stdout:close()
      stderr:close()
    end)
    return nil, "spawn failed: " .. tostring(pid_or_err)
  end
  s.handle = handle

  vim.uv.read_start(stdout, function(_err, data)
    if data then
      s.out = s.out .. data
    end
  end)
  vim.uv.read_start(stderr, function(_err, data)
    if data then
      s.out = s.out .. data
    end
  end)
  return s
end

-- Public: ensure a session exists for (lang, name); spawn if needed.
function M.ensure(lang, name)
  local k = key(lang, name)
  local s = M._sessions[k]
  if s and s.alive then
    return s
  end
  if s then
    M._sessions[k] = nil
  end -- dead, drop it
  local fresh, err = spawn(lang)
  if not fresh then
    return nil, err
  end
  M._sessions[k] = fresh
  return fresh
end

-- Public: evaluate `body` in (lang, name)'s session. Returns the
-- captured output string, or nil + err on failure.
function M.eval(lang, name, body, timeout_ms)
  local s, err = M.ensure(lang, name)
  if not s then
    return nil, err
  end
  local sentinel = "__ORG_BABEL_END_" .. tostring(math.random(1, 1e9)) .. "__"
  s.out = ""
  local marker = s.conf.sentinel_fn(sentinel)
  -- Write body + a newline + the marker.
  vim.uv.write(s.stdin, body .. "\n" .. marker .. "\n")
  local got = vim.wait(timeout_ms or 10000, function()
    return s.out:find(sentinel, 1, true) ~= nil
  end, 20)
  if not got then
    return nil, "timed out waiting for session output (sentinel: " .. sentinel .. ")"
  end
  local before = s.out:match("^(.-)" .. sentinel) or s.out
  return s.conf.clean(before), nil
end

-- Public: stop a single session (or all matching `lang` if name is nil).
function M.stop_session(lang, name)
  if name then
    local k = key(lang, name)
    local s = M._sessions[k]
    if not s then
      return
    end
    pcall(function()
      s.handle:kill("sigterm")
    end)
    pcall(function()
      s.stdin:close()
      s.stdout:close()
      s.stderr:close()
    end)
    M._sessions[k] = nil
  else
    -- Stop all sessions of this language.
    for k, s in pairs(M._sessions) do
      if s.lang == lang then
        pcall(function()
          s.handle:kill("sigterm")
        end)
        pcall(function()
          s.stdin:close()
          s.stdout:close()
          s.stderr:close()
        end)
        M._sessions[k] = nil
      end
    end
  end
end

function M.stop_all()
  for k, s in pairs(M._sessions) do
    pcall(function()
      s.handle:kill("sigterm")
    end)
    pcall(function()
      s.stdin:close()
      s.stdout:close()
      s.stderr:close()
    end)
    M._sessions[k] = nil
  end
end

function M.list()
  local out = {}
  for k, s in pairs(M._sessions) do
    out[#out + 1] = { key = k, lang = s.lang, alive = s.alive }
  end
  return out
end

-- Auto-cleanup on nvim exit.
local _autocmd_installed = false
function M._install_autocmd()
  if _autocmd_installed then
    return
  end
  _autocmd_installed = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.stop_all()
    end,
  })
end

return M
