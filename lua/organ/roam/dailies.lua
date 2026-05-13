local M = {}

local function dailies_dir()
  local cfg = (require("organ.buf_config").read(nil, "roam") or {})
  local roam_dir = cfg.dir or vim.fn.expand("~/org/roam")
  local subdir = (cfg.dailies or {}).subdir or "daily"
  return roam_dir .. "/" .. subdir
end

local function default_template(iso)
  local id = require("organ.uuid").v7()
  return {
    ":PROPERTIES:",
    ":ID:       " .. id,
    ":END:",
    "#+title: " .. iso,
    "",
    "",
  }
end

local function _open_or_create(iso)
  local dir = dailies_dir()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. iso .. ".org"
  if not vim.loop.fs_stat(path) then
    local cfg = (require("organ.buf_config").read(nil, "roam") or {})
    local tpl = (cfg.dailies or {}).template or default_template
    local body = tpl(iso)
    require("organ.path").write_atomic(path, table.concat(body, "\n") .. "\n")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  -- Cursor at end (typical "start writing" position).
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { last, 0 })
end

function M.for_date(iso)
  _open_or_create(iso)
end
function M.today()
  _open_or_create(os.date("%Y-%m-%d"))
end
function M.yesterday()
  _open_or_create(os.date("%Y-%m-%d", os.time() - 86400))
end
function M.tomorrow()
  _open_or_create(os.date("%Y-%m-%d", os.time() + 86400))
end

function M.pick_date()
  require("organ.calendar").pick({ title = "Pick a daily date" }, function(iso)
    if iso then
      _open_or_create(iso)
    end
  end)
end

return M
