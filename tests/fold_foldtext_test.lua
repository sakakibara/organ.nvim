-- Foldtext renderers + dispatcher: `fold.foldtext` config selects
-- between "emacs" (default), "items", a custom function, or off.
--
-- Run via: nvim --headless -l tests/fold_foldtext_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local fold = require("organ.fold")
local cfg = require("organ").config.fold

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Build a buffer with a 3-line fold ("body" + 1 line) under H1.
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H1", "body 1", "body 2" })
vim.bo[b].filetype = "org"

-- vim.v.foldstart / foldend are read by the renderers.  Stub via the
-- `vim.v` table.
local function with_fold(foldstart, foldend, fn)
  local s, e = vim.v.foldstart, vim.v.foldend
  vim.cmd("let v:foldstart = " .. foldstart)
  vim.cmd("let v:foldend = " .. foldend)
  local ok, out = pcall(fn)
  vim.cmd("let v:foldstart = " .. s)
  vim.cmd("let v:foldend = " .. e)
  if not ok then
    error(out)
  end
  return out
end

-- foldtext can return a string or a list of {text, hl} segments
-- (treesitter-aware path).  Normalise for assertions.
local function as_string(v)
  if type(v) == "string" then
    return v
  end
  local parts = {}
  for _, seg in ipairs(v) do
    parts[#parts + 1] = seg[1]
  end
  return table.concat(parts)
end

-- Default config -> "emacs" -> "* H1 …" with content present.
check("default config = 'emacs'", cfg.foldtext == "emacs", "got " .. tostring(cfg.foldtext))
local out = with_fold(1, 3, function()
  return fold.foldtext()
end)
local out_s = as_string(out)
check("emacs renderer ends with ' …'", out_s:sub(-#" …") == " …", "got " .. tostring(out_s))
check("emacs renderer starts with heading", out_s:find("^%* H1") ~= nil)

-- All-blank body -> no ellipsis suffix.
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H1", "", "" })
local blank_out = with_fold(1, 3, function()
  return fold.foldtext()
end)
local blank_s = as_string(blank_out)
check("all-blank body: no ellipsis suffix", blank_s == "* H1", "got " .. tostring(blank_s))

-- Custom function.
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H1", "body 1", "body 2" })
cfg.foldtext = function(s, e)
  return string.format("[%d-%d] custom", s, e)
end
local fn_out = with_fold(1, 3, function()
  return fold.foldtext()
end)
check("custom function applied", fn_out == "[1-3] custom", "got " .. tostring(fn_out))

-- Custom function that errors -> safe fallback to heading line.
cfg.foldtext = function()
  error("oops")
end
local fb_out = with_fold(1, 3, function()
  return fold.foldtext()
end)
check("erroring custom function -> heading line fallback", fb_out == "* H1")

cfg.foldtext = "emacs"

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_foldtext_test: PASS")
os.exit(0)
