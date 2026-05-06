-- Headless index entrypoint. Invocation:
--   nvim --headless --cmd "set rtp^=." -l scripts/index.lua --db <path> --file <file.org>
--   nvim --headless --cmd "set rtp^=." -l scripts/index.lua --db <path> --dir  <dir>

-- When invoked via `nvim -l script.lua --key val`, arguments land in the
-- global `arg` table starting at index 1 (index 0 is the script path).
-- The vararg `{...}` is always empty under nvim -l.
local cli = arg or {}
local opts = {}
local i = 1
while i <= #cli do
  local k = cli[i]:gsub("^%-%-", "")
  opts[k] = cli[i + 1]
  i = i + 2
end

if not opts.db then io.stderr:write("missing --db\n"); os.exit(2) end
if not (opts.file or opts.dir) then io.stderr:write("missing --file or --dir\n"); os.exit(2) end

local organ = require("organ")
organ.setup({
  db_path = opts.db,
  org_dir = opts.dir or vim.fn.fnamemodify(opts.file, ":h"),
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})

if opts.file then
  require("organ.queue").enqueue_interactive(vim.fn.fnamemodify(opts.file, ":p"))
  if not require("organ.queue").drain_blocking(60000) then
    io.stderr:write("drain timeout\n"); os.exit(3)
  end
else
  if not organ.scan_blocking(opts.dir, 600000) then
    io.stderr:write("scan timeout\n"); os.exit(3)
  end
end

os.exit(0)
