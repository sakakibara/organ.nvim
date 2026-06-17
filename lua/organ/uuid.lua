-- UUID generation for organ.nvim.
--   v7 (RFC 9562): 48-bit ms-since-epoch prefix + 74 random bits, so
--      lexical sort matches creation order.
--   v4 (RFC 4122): 122 random bits.  Byte-for-byte the shape Emacs
--      `org-id` emits under its default `org-id-method` = uuid.

local M = {}

math.randomseed(os.time() + (vim.uv.hrtime() % 1e9))

local function r(n)
  return math.random(0, 2 ^ n - 1)
end

function M.v7()
  local sec, usec = vim.uv.gettimeofday()
  local ms = sec * 1000 + math.floor(usec / 1000)
  -- Split 48-bit ms into high 32 + low 16 (Lua doubles handle 48 bits exactly).
  local hi = math.floor(ms / 0x10000)
  local lo = ms % 0x10000
  return string.format(
    "%08x-%04x-7%03x-%04x-%04x%08x",
    hi,
    lo,
    r(12), -- rand_a (12 bits after version nibble)
    0x8000 + r(14), -- variant 0b10 in top 2 bits + 14 bits random
    r(16),
    r(32)
  ) -- 48 bits rand_b
end

function M.v4()
  return string.format(
    "%08x-%04x-4%03x-%04x-%04x%08x",
    r(32), -- 32 random bits
    r(16), -- 16 random bits
    r(12), -- 12 bits after the version nibble (4)
    0x8000 + r(14), -- variant 0b10 in top 2 bits + 14 bits random
    r(16),
    r(32)
  ) -- 48 random bits
end

return M
