-- organ.compat.sha256 hashes any bytes, NUL included, on every supported
-- Neovim, and its pure-Lua path matches the standard test vectors.
-- Run via: nvim --headless -l tests/compat_sha256_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local compat = require("organ.compat")
local failures = 0
local function eq(name, got, want)
  if got ~= want then
    failures = failures + 1
    io.write(string.format("FAIL %s: got %s want %s\n", name, tostring(got), want))
  end
end

local vectors = {
  { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
  { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
  {
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  },
  { string.rep("a", 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
}
for i, v in ipairs(vectors) do
  eq("vector " .. i, compat._sha256_lua(v[1]), v[2])
  eq("vector " .. i .. " public", compat.sha256(v[1]), v[2])
end

-- Every padding boundary, and bytes the builtin rejects on 0.11.
math.randomseed(7)
for len = 0, 200 do
  local t = {}
  for i = 1, len do
    t[i] = string.char(math.random(0, 255))
  end
  local s = table.concat(t)
  local got = compat.sha256(s)
  eq("lua path len " .. len, compat._sha256_lua(s), got)
  if not s:find("\0", 1, true) then
    eq("builtin len " .. len, got, vim.fn.sha256(s))
  elseif vim.fn.has("nvim-0.12") == 1 then
    eq("builtin nul len " .. len, got, vim.fn.sha256(s))
  end
end
eq("nul", compat.sha256("a\0b"), "59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138")

if failures > 0 then
  os.exit(1)
end
io.write("compat sha256 ok\n")
