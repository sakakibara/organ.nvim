-- Pure unit: path.canonical normalises to absolute, symlink-resolved, no trailing slash.
-- Run via: nvim --headless -l tests/path_canonical_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local path = require("organ.path")

-- Defensive: nil / empty / non-string return nil.
assert(path.canonical(nil) == nil, "nil → nil")
assert(path.canonical("") == nil, "empty → nil")
assert(path.canonical(123) == nil, "number → nil")

-- Trailing slash stripped.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local with_slash = path.canonical(tmp .. "/")
local without_slash = path.canonical(tmp)
assert(
  with_slash == without_slash,
  "trailing slash should be stripped: " .. tostring(with_slash) .. " vs " .. tostring(without_slash)
)
assert(not with_slash:match("/$"), "no trailing slash: " .. with_slash)

-- Idempotent.
assert(path.canonical(without_slash) == without_slash, "idempotent")

-- Relative path becomes absolute (resolved via cwd).
local rel_canon = path.canonical("README")
assert(rel_canon and rel_canon:sub(1, 1) == "/", "relative → absolute: " .. tostring(rel_canon))

-- Symlinked dir: write a file, create a symlink to its parent, canonical of the
-- symlink path matches canonical of the real path.
local real = tmp .. "/real"
vim.fn.mkdir(real, "p")
local link = tmp .. "/link"
vim.loop.fs_symlink(real, link)
local file_real = real .. "/x.org"
local file_link = link .. "/x.org"
local fh = assert(io.open(file_real, "w"))
fh:write("* X\n")
fh:close()

local c_real = path.canonical(file_real)
local c_link = path.canonical(file_link)
assert(
  c_real == c_link,
  "symlink should resolve: real=" .. tostring(c_real) .. " link=" .. tostring(c_link)
)

-- Non-existent path: falls back to :p form (does NOT return nil).
local missing = tmp .. "/does/not/exist.org"
local c_miss = path.canonical(missing)
assert(
  c_miss and c_miss:sub(1, 1) == "/",
  "non-existent path should still return a usable absolute key: " .. tostring(c_miss)
)

vim.fn.delete(tmp, "rf")
io.write("path canonical ok\n")
os.exit(0)
