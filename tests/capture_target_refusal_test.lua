-- A capture target organ cannot resolve is refused before anything is
-- written: an unsupported kind or a missing path must not create a file
-- (a missing path used to become a file named "v:null" in the cwd).
-- Run via: nvim --headless -l tests/capture_target_refusal_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local target = require("organ.capture.target")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.cmd.cd(tmp)

local failures = 0
local function refused(name, spec)
  local ok, err = pcall(target.resolve, spec, {}, false)
  local leftovers = vim.fn.readdir(tmp)
  if ok or #leftovers > 0 then
    failures = failures + 1
    io.write(
      string.format(
        "FAIL %s: ok=%s err=%s files=%s\n",
        name,
        tostring(ok),
        tostring(err),
        vim.inspect(leftovers)
      )
    )
  end
end

refused("unsupported kind", { kind = "id", id = "abc" })
refused("missing path", { kind = "file" })
refused("empty path", { kind = "file_headline", path = "", headline = "Inbox" })
refused("function without a path", {
  kind = "file_function",
  fn = function()
    return nil
  end,
})
refused("function with an empty path", {
  kind = "file_function",
  fn = function()
    return "", 1
  end,
})

vim.cmd.cd(root)
vim.fn.delete(tmp, "rf")
if failures > 0 then
  os.exit(1)
end
io.write("capture target refusal ok\n")
