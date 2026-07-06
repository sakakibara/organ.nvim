local M = {}

local function dailies_dir()
  local cfg = (require("organ.buf_config").read(nil, "roam") or {})
  local roam_dir = cfg.dir or vim.fn.expand("~/org/roam")
  local subdir = (cfg.dailies or {}).subdir or "daily"
  return roam_dir .. "/" .. subdir
end

local function default_template(iso)
  local note = require("organ.roam.note")
  local lines = note.header(require("organ.id").generate(), iso)
  -- org-roam's default daily capture is an `entry "* %?"` template, so a
  -- fresh daily opens on a new heading ready to type.
  lines[#lines + 1] = "* "
  return lines
end

local function _open_or_create(iso)
  local path = dailies_dir() .. "/" .. iso .. ".org"
  if vim.loop.fs_stat(path) then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local last = vim.api.nvim_buf_line_count(0)
    local last_text = vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1] or ""
    vim.api.nvim_win_set_cursor(0, { last, #last_text })
    return
  end
  -- A brand-new daily opens unsaved, seeded from the template; see
  -- organ.roam.note.open_unsaved for why it stays off disk until written.
  local cfg = (require("organ.buf_config").read(nil, "roam") or {})
  local tpl = (cfg.dailies or {}).template or default_template
  require("organ.roam.note").open_unsaved(path, tpl(iso))
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
