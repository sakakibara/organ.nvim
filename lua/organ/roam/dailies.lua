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
  local dir = dailies_dir()
  local path = dir .. "/" .. iso .. ".org"
  local existed = vim.loop.fs_stat(path) ~= nil
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  if not existed then
    -- A brand-new daily opens as an UNSAVED buffer seeded with the
    -- template; it becomes a file only when the user writes it, so opening
    -- today's daily and quitting without typing leaves nothing on disk
    -- (matches Emacs org-roam capture).  Defer the mkdir to the first write
    -- so the directory doesn't materialize on a peek-and-quit either.
    local cfg = (require("organ.buf_config").read(nil, "roam") or {})
    local tpl = (cfg.dailies or {}).template or default_template
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, tpl(iso))
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      once = true,
      callback = function()
        vim.fn.mkdir(dir, "p")
      end,
    })
  end
  -- Land at the end of the last line -- the seeded `* ` heading for the
  -- default template, so typing continues the heading title.
  local last = vim.api.nvim_buf_line_count(bufnr)
  local last_text = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { last, #last_text })
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
