-- lua/organ/attach.lua
-- File-attachment support: :Org attach / :Org attach open / :Org attach reveal.
-- Mirrors Emacs org-attach (data/<id[:2]>/<id[3:]>/ layout under attach.dir).

local M = {}

local obuf = require("organ.buf")
-- Compute the attachment directory for a given headline ID.
-- Layout is selected by `attach.id_dir_layout`:
--   "two_three"  → `<base_dir>/<id[1..2]>/<id[3..]>/`  (Emacs default)
--   "flat"       → `<base_dir>/<id>/`
-- Returns nil if id is nil (or shorter than 3 chars under two_three).
function M.dir_for_id(base_dir, id)
  if not id or id == "" then
    return nil
  end
  local layout = (require("organ.buf_config").read(nil, "attach") or {}).id_dir_layout
    or "two_three"
  if layout == "flat" then
    return base_dir .. "/" .. id
  end
  if #id < 3 then
    return nil
  end
  return base_dir .. "/" .. id:sub(1, 2) .. "/" .. id:sub(3)
end

-- Return the attachment directory for the headline containing `line` in `bufnr`.
-- Creates an :ID: if necessary unless `opts.create == false`.  Returns (dir, err).
function M.dir(bufnr, line, opts)
  local id_mod = require("organ.id")
  local id
  if opts and opts.create == false then
    id = id_mod.get(bufnr, line)
    if not id then
      return nil, "headline has no ID"
    end
  else
    id = id_mod.get_or_create(bufnr, line)
    if not id then
      return nil, "could not get or create headline ID"
    end
  end

  local base = (require("organ.buf_config").read(nil, "attach") or {}).dir
    or (vim.fn.expand("~/org/data"))
  local d = M.dir_for_id(base, id)
  if not d then
    return nil, "ID too short to derive attachment directory"
  end
  return d, nil
end

-- List files in the attachment directory of the headline at `line`.
-- Returns (files_list, err); files_list is a list of full paths.
function M.list(bufnr, line)
  local d, err = M.dir(bufnr, line)
  if err then
    return nil, err
  end

  if not vim.loop.fs_stat(d) then
    return {}, nil
  end

  local files = {}
  local handle = vim.loop.fs_scandir(d)
  if not handle then
    return {}, nil
  end
  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if ftype == "file" then
      files[#files + 1] = d .. "/" .. name
    end
  end
  table.sort(files)
  return files, nil
end

-- Attach `src_path` to the headline at `line` in `bufnr`.
-- Copies (or symlinks) the file into the attachment dir.
-- If `auto_insert_link` is true, inserts [[attachment:<filename>]] at cursor.
-- Returns err or nil.
function M.attach(bufnr, line, src_path)
  local attach_cfg = require("organ.buf_config").read(nil, "attach") or {}

  src_path = vim.fn.fnamemodify(src_path, ":p")
  if not vim.loop.fs_stat(src_path) then
    return "no such file: " .. src_path
  end

  local d, err = M.dir(bufnr, line)
  if err then
    return err
  end

  -- Create attachment directory.
  vim.fn.mkdir(d, "p")

  local filename = vim.fn.fnamemodify(src_path, ":t")
  local dest = d .. "/" .. filename

  -- Copy or symlink.
  local use_symlinks = attach_cfg.use_symlinks == true
  if use_symlinks then
    local ok = vim.loop.fs_symlink(src_path, dest)
    if not ok then
      return "symlink failed: " .. src_path .. " → " .. dest
    end
  else
    local ok, content = pcall(vim.fn.readfile, src_path, "b")
    if not ok then
      return "cannot read " .. src_path
    end
    vim.fn.writefile(content, dest, "b")
  end

  -- Optionally insert link at cursor.
  local auto = attach_cfg.auto_insert_link
  if auto == nil then
    auto = true
  end
  if auto then
    local link_text = "[[attachment:" .. filename .. "]]"
    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local crow = cur[1]
    local ccol = cur[2]
    local line_text = vim.api.nvim_buf_get_lines(bufnr, crow - 1, crow, false)[1] or ""
    local new_text = line_text:sub(1, ccol) .. link_text .. line_text:sub(ccol + 1)
    obuf.set_lines(bufnr, crow - 1, crow, { new_text })
  end

  return nil
end

-- Attach from URL: download to attachment dir + insert link.
--
-- Uses curl (preferred) or wget. Filename derived from URL's last path
-- component (or fallback to a hash of the URL).
function M.attach_url(bufnr, line, url)
  if not url or url == "" then
    return "no url"
  end
  local d, err = M.dir(bufnr, line)
  if err then
    return err
  end
  vim.fn.mkdir(d, "p")

  -- Pick filename: last path segment, fallback to "download".
  local filename = url:match("/([^/?#]+)[^/]*$")
  if not filename or filename == "" then
    filename = "download"
  end
  local dest = d .. "/" .. filename

  local cmd
  if vim.fn.executable("curl") == 1 then
    cmd = { "curl", "--silent", "--show-error", "--fail", "--location", "--output", dest, url }
  elseif vim.fn.executable("wget") == 1 then
    cmd = { "wget", "--quiet", "-O", dest, url }
  else
    return "neither curl nor wget on PATH"
  end

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return ("download failed (%d): %s"):format(vim.v.shell_error, out)
  end

  -- Insert link if configured.
  local auto = (require("organ.buf_config").read(nil, "attach") or {}).auto_insert_link
  if auto == nil then
    auto = true
  end
  if auto then
    local link_text = "[[attachment:" .. filename .. "]]"
    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local crow, ccol = cur[1], cur[2]
    local line_text = vim.api.nvim_buf_get_lines(bufnr, crow - 1, crow, false)[1] or ""
    local new_text = line_text:sub(1, ccol) .. link_text .. line_text:sub(ccol + 1)
    obuf.set_lines(bufnr, crow - 1, crow, { new_text })
  end

  return nil, filename
end

-- Screenshot to attachment dir + insert link.
--
-- Uses an OS-appropriate screenshot tool:
--   macOS  → `screencapture -i <path>` (interactive)
--   Linux  → `flameshot gui --raw > <path>` (preferred), then `maim -s <path>`
-- Returns err string on failure or nil on success.
function M.attach_screenshot(bufnr, line, opts)
  opts = opts or {}
  local d, err = M.dir(bufnr, line)
  if err then
    return err
  end
  vim.fn.mkdir(d, "p")

  local filename = opts.filename or os.date("screenshot-%Y%m%d-%H%M%S.png")
  local dest = d .. "/" .. filename

  local sysname = (vim.uv.os_uname() or {}).sysname or ""
  if sysname == "Darwin" and vim.fn.executable("screencapture") == 1 then
    -- -i = interactive (user selects region).
    vim.fn.system({ "screencapture", "-i", dest })
  elseif vim.fn.executable("flameshot") == 1 then
    -- flameshot gui --raw writes PNG to stdout; redirect via shell.
    vim.fn.system("flameshot gui --raw > " .. vim.fn.shellescape(dest))
  elseif vim.fn.executable("maim") == 1 then
    vim.fn.system({ "maim", "-s", dest })
  else
    return "no screenshot tool on PATH (tried: screencapture, flameshot, maim)"
  end
  if vim.v.shell_error ~= 0 then
    return ("screenshot failed (%d)"):format(vim.v.shell_error)
  end
  if not vim.loop.fs_stat(dest) then
    return "screenshot tool exited 0 but no file was written (likely cancelled)"
  end

  local auto = (require("organ.buf_config").read(nil, "attach") or {}).auto_insert_link
  if auto == nil then
    auto = true
  end
  if auto then
    local link_text = "[[attachment:" .. filename .. "]]"
    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local crow, ccol = cur[1], cur[2]
    local line_text = vim.api.nvim_buf_get_lines(bufnr, crow - 1, crow, false)[1] or ""
    local new_text = line_text:sub(1, ccol) .. link_text .. line_text:sub(ccol + 1)
    obuf.set_lines(bufnr, crow - 1, crow, { new_text })
  end

  return nil, filename
end

-- org-attach-git: version-control the attachment dir.
--
-- Opt-in via config.attach.git = true. On each successful attach (file /
-- url / screenshot), the attachment dir is initialised as a git repo on
-- first use, then `git add <file>` + `git commit -m "..."` runs.
--
-- No-op + warn when git isn't on PATH (so nothing breaks for users who
-- enable the flag without git installed).

local function _git_run(dir, ...)
  local args = { "git", "-C", dir }
  for _, a in ipairs({ ... }) do
    args[#args + 1] = a
  end
  local out = vim.fn.system(args)
  return vim.v.shell_error, out
end

-- Initialise `dir` as a git repo iff not already one.
local function _ensure_git_repo(dir)
  if vim.fn.executable("git") ~= 1 then
    return false, "git not on PATH"
  end
  if vim.uv.fs_stat(dir .. "/.git") then
    return true
  end
  vim.fn.mkdir(dir, "p")
  local rc, out = _git_run(dir, "init", "--quiet")
  if rc ~= 0 then
    return false, "git init failed: " .. out
  end
  -- Set a basic identity if not already configured globally; otherwise
  -- `git commit` errors on a fresh repo with `unable to auto-detect email`.
  _git_run(dir, "config", "--get", "user.email")
  if vim.v.shell_error ~= 0 then
    _git_run(dir, "config", "user.email", "organ-attach@local")
    _git_run(dir, "config", "user.name", "organ.nvim")
  end
  return true
end

-- Stage + commit `relpath` (relative to `dir`) with a default message.
-- Returns nil on success, error string otherwise.
local function _git_commit(dir, relpath, message)
  if vim.fn.executable("git") ~= 1 then
    require("organ.notify").warn("attach.git enabled but git not on PATH")
    return "git not on PATH"
  end
  local ok, err = _ensure_git_repo(dir)
  if not ok then
    return err
  end
  local rc, out = _git_run(dir, "add", "--", relpath)
  if rc ~= 0 then
    return "git add failed: " .. out
  end
  rc, out = _git_run(dir, "commit", "-m", message, "--quiet")
  if rc ~= 0 then
    return "git commit failed: " .. out
  end
  return nil
end

-- Commit `filename` in the headline's attachment dir if git mode is
-- enabled. Used by attach / attach_url / attach_screenshot after each
-- successful attach.
local function maybe_git_commit(bufnr, line, filename, action)
  local cfg = (require("organ.buf_config").read(nil, "attach") or {})
  if cfg.git ~= true then
    return
  end
  local dir, err = M.dir(bufnr, line)
  if err or not dir then
    return
  end
  local message = string.format("organ: %s %s", action or "attach", filename)
  local err2 = _git_commit(dir, filename, message)
  if err2 then
    require("organ.notify").warn("organ: attach.git: " .. err2)
  end
end

-- Wrap the existing public functions so the git commit fires automatically.
-- We do this monkey-patch style at module-load to avoid touching every
-- caller; original implementations stay accessible via `_orig_*`.
local _orig_attach = M.attach
local _orig_attach_url = M.attach_url
local _orig_attach_screenshot = M.attach_screenshot

function M.attach(bufnr, line, src_path)
  local err = _orig_attach(bufnr, line, src_path)
  if not err then
    maybe_git_commit(bufnr, line, vim.fn.fnamemodify(src_path, ":t"), "attach")
  end
  return err
end

function M.attach_url(bufnr, line, url)
  local err, name = _orig_attach_url(bufnr, line, url)
  if not err and name then
    maybe_git_commit(bufnr, line, name, "attach url")
  end
  return err, name
end

function M.attach_screenshot(bufnr, line, opts)
  local err, name = _orig_attach_screenshot(bufnr, line, opts)
  if not err and name then
    maybe_git_commit(bufnr, line, name, "attach screenshot")
  end
  return err, name
end

local function notify_info(msg)
  if require("organ.buf_config").read(nil, "notify") then
    require("organ.errors").schedule("organ.attach", function()
      require("organ.notify").info(msg)
    end)
  end
end

local function bufnr_line()
  return vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1]
end

M.commands = {
  attach = {
    fn = function(cmd)
      local bufnr, line = bufnr_line()
      local function do_attach(path)
        if not path or path == "" then
          notify_info("no file specified")
          return
        end
        local err = M.attach(bufnr, line, path)
        if err then
          require("organ.notify").error(err)
        else
          notify_info("attached: " .. vim.fn.fnamemodify(path, ":t"))
        end
      end
      if cmd and cmd.args and cmd.args ~= "" then
        do_attach(cmd.args)
      else
        vim.ui.input({ prompt = "Attach file: ", completion = "file" }, do_attach)
      end
    end,
    nargs = "?",
    complete = "file",
    desc = "Attach a file to the current headline (copies into data/<id>/ dir)",
  },
  ["attach open"] = {
    fn = function()
      local bufnr, line = bufnr_line()
      local files, err = M.list(bufnr, line)
      if err then
        require("organ.notify").error(err)
        return
      end
      if not files or #files == 0 then
        notify_info("no attached files")
        return
      end
      local labels = {}
      for _, f in ipairs(files) do
        labels[#labels + 1] = vim.fn.fnamemodify(f, ":t")
      end
      vim.ui.select(labels, { prompt = "Open attachment: " }, function(choice, idx)
        if not choice or not files[idx] then
          return
        end
        vim.cmd("edit " .. vim.fn.fnameescape(files[idx]))
      end)
    end,
    desc = "Open a file attached to the current headline",
  },
  ["attach reveal"] = {
    fn = function()
      local bufnr, line = bufnr_line()
      local d, err = M.dir(bufnr, line)
      if err then
        require("organ.notify").error(err)
        return
      end
      vim.cmd("edit " .. vim.fn.fnameescape(d))
    end,
    desc = "Open (reveal) the attachment directory of the current headline",
  },
  ["attach url"] = {
    fn = function(cmd)
      local url = cmd and cmd.args or ""
      if url == "" then
        require("organ.notify").warn(":Org attach url requires a URL")
        return
      end
      local bufnr, line = bufnr_line()
      local err, name = M.attach_url(bufnr, line, url)
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("organ: attached " .. tostring(name))
      end
    end,
    nargs = 1,
    desc = "Download a URL into the headline's attachment dir + insert link",
  },
  ["attach screenshot"] = {
    fn = function()
      local bufnr, line = bufnr_line()
      local err, name = M.attach_screenshot(bufnr, line)
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("organ: attached " .. tostring(name))
      end
    end,
    desc = "Take an interactive screenshot, save to attachment dir + insert link",
  },
}

return M
