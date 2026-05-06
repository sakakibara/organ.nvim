-- Progressive enhancement for picker icons:
--   1. mini.icons preferred
--   2. nvim-web-devicons fallback
--   3. nil when neither is loaded — caller drops the icon segment
--
-- Run via: nvim --headless -l tests/icons_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = vim.fn.tempname(),
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local icons = require("organ.icons")

-- ---------------------------------------------------------------------------
-- (a) Neither provider loaded → icons.get returns nil.
-- ---------------------------------------------------------------------------
package.loaded["mini.icons"] = nil
package.loaded["nvim-web-devicons"] = nil
icons._reset_cache()

local ic, hl = icons.get("/tmp/foo.org")
check("no provider: icons.get returns nil", ic == nil and hl == nil)

local seg = icons.segment("/tmp/foo.org")
check("no provider: icons.segment returns nil", seg == nil)

-- ---------------------------------------------------------------------------
-- (b) mini.icons mocked → icons.get routes through it.
-- ---------------------------------------------------------------------------
local mini_calls = 0
package.loaded["mini.icons"] = {
  get = function(category, path)
    mini_calls = mini_calls + 1
    return "M", "MiniIconOrg"
  end,
}
icons._reset_cache()

local ic2, hl2 = icons.get("/tmp/foo.org")
check("mini.icons: icon returned", ic2 == "M" and hl2 == "MiniIconOrg")
check("mini.icons: get() was invoked", mini_calls == 1)

local seg2 = icons.segment("/tmp/foo.org")
check(
  "mini.icons: segment() builds {icon..space, hl}",
  seg2 and seg2[1] == "M " and seg2[2] == "MiniIconOrg",
  seg2 and vim.inspect(seg2)
)

-- ---------------------------------------------------------------------------
-- (c) When mini.icons is absent, nvim-web-devicons is the fallback.
-- ---------------------------------------------------------------------------
package.loaded["mini.icons"] = nil
local dev_calls = 0
package.loaded["nvim-web-devicons"] = {
  get_icon = function(name, ext, opts)
    dev_calls = dev_calls + 1
    return "D", "DevIconOrg"
  end,
  get_icon_by_filetype = function(ft, opts)
    return "F", "DevIconFt"
  end,
}
icons._reset_cache()

local ic3, hl3 = icons.get("/tmp/foo.org")
check("devicons: icon returned via get_icon", ic3 == "D" and hl3 == "DevIconOrg")
check("devicons: get_icon() was invoked", dev_calls == 1)

local ic4, hl4 = icons.get("org", "filetype")
check("devicons: filetype lookup works", ic4 == "F" and hl4 == "DevIconFt")

-- Cleanup.
package.loaded["mini.icons"] = nil
package.loaded["nvim-web-devicons"] = nil
icons._reset_cache()

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("icons_test: PASS")
