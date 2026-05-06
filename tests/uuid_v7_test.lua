-- Pure unit: uuid.v7() returns RFC 9562 UUID v7 strings. Lexical sort matches
-- generation order across a 100ms gap.
-- Run via: nvim --headless -l tests/uuid_v7_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local uuid = require("organ.uuid")

-- Shape: 8-4-4-4-12 hex; 13th nibble (version) = 7; 17th nibble (variant high
-- bits) ∈ {8, 9, a, b}.
local function shape(s)
  return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
end

local id1 = uuid.v7()
assert(shape(id1), "id1 doesn't match v7 shape: " .. tostring(id1))

local id2 = uuid.v7()
assert(shape(id2), "id2 doesn't match v7 shape: " .. tostring(id2))
assert(id1 ~= id2, "two consecutive calls returned the same id")

-- Lexical sort matches creation order (after a 100ms gap so the time bits differ).
vim.cmd("sleep 100m")
local id3 = uuid.v7()
assert(shape(id3))
assert(id1 < id3, "lexical sort: " .. id1 .. " should be < " .. id3)
assert(id2 < id3, "lexical sort: " .. id2 .. " should be < " .. id3)

io.write("uuid v7 ok\n")
os.exit(0)
