-- A live `#+CATEGORY:` directive edit must show on the next agenda render.
-- format.lua caches the file-directive lookup per render; without the
-- per-render reset the agenda keeps the old category until nvim restarts.
-- Run via: nvim --headless -l tests/agenda_category_refresh_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local format = require("organ.agenda.format")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local path = os.tmpname() .. ".org"
local function write(category)
  local fd = assert(io.open(path, "w"))
  fd:write("#+CATEGORY: " .. category .. "\n* TODO task\n")
  fd:close()
end

-- No :CATEGORY: property, so resolution falls to the file directive.
local r = { file_path = path }

write("Alpha")
format.reset_caches()
check(format.category_for(r) == "Alpha", "category resolves from the #+CATEGORY: directive")

-- Within one render pass the value is cached: rows sharing a file read once.
write("Beta")
check(format.category_for(r) == "Alpha", "cached within a render (no mid-pass re-read)")

-- The next render resets the cache and picks up the edit.
format.reset_caches()
check(format.category_for(r) == "Beta", "directive edit shows after the per-render reset")

os.remove(path)
print("agenda_category_refresh_test: PASS")
