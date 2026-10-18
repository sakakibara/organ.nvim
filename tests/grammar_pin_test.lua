-- The parsers the suite loads are the ones the build manifest describes,
-- built from the revisions grammar_install pins.  A parser built from
-- ORGAN_GRAMMAR_SRC passes locally and fails in CI.
-- Run via: make test (or nvim --headless -l tests/grammar_pin_test.lua
-- with the same XDG_DATA_HOME the Makefile sets).

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local gi = require("organ.grammar_install")
local compat = require("organ.compat")

local failures = 0
local function fail(msg)
  failures = failures + 1
  io.write("FAIL " .. msg .. "\n")
end

local manifest
local fd = io.open(gi.install_path(".build-manifest.json"), "r")
if fd then
  local ok, decoded = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  manifest = ok and decoded or nil
end
if type(manifest) ~= "table" then
  fail("no build manifest beside the parsers; run `make grammar`")
  os.exit(1)
end

local in_ci = vim.env.CI ~= nil and vim.env.CI ~= ""
local pins = gi.pins()
for _, file in ipairs({ "org.so", "org_inline.so" }) do
  local entry = manifest[file]
  local path = gi.path(file)
  local f = io.open(path, "rb")
  local bytes = f and f:read("*a")
  if f then
    f:close()
  end
  if type(entry) ~= "table" or not entry.sha256 then
    fail(file .. ": the manifest records no hash; run `make grammar`")
  elseif not bytes then
    fail(file .. ": not readable at " .. path)
  elseif compat.sha256(bytes) ~= entry.sha256 then
    fail(file .. ": the loaded parser is not the one the manifest records; run `make grammar`")
  elseif entry.local_src then
    if in_ci then
      fail(file .. ": built from ORGAN_GRAMMAR_SRC " .. entry.local_src)
    else
      io.write(file .. ": built from ORGAN_GRAMMAR_SRC " .. entry.local_src .. "\n")
    end
  elseif entry.rev ~= pins[entry.repo] then
    fail(
      ("%s: built from %s, pinned %s; run `make grammar`"):format(
        file,
        tostring(entry.rev),
        tostring(pins[entry.repo])
      )
    )
  end
end

if failures > 0 then
  os.exit(1)
end
io.write("grammar pin ok\n")
