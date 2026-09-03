-- Verifies organ.entities maps LaTeX names to unicode and applies
-- conceal extmarks on attach.
-- Run via: nvim --headless -l tests/entities_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local ent = require("organ.entities")

assert(ent.lookup("\\alpha") == "α", "alpha lookup")
assert(ent.lookup("\\to") == "→", "to lookup")
assert(ent.lookup("\\sum") == "∑", "sum lookup")
assert(ent.lookup("\\not_a_real_entity") == nil, "unknown returns nil")

-- Extra entities via config.
local organ = require("organ")
organ.config.entities = { extra = { foo = "🦊" } }
ent.refresh()
assert(ent.lookup("\\foo") == "🦊", "extras override")

-- Attach decorates the buffer.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "Math: \\alpha + \\beta = \\gamma",
  "Plain text without entities",
  "Arrow: A \\to B",
})
ent.attach(bufnr)
vim.wait(50) -- drain deferred initial apply

local NS = vim.api.nvim_create_namespace("organ_entities")
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
local conceals = {}
for _, m in ipairs(marks) do
  local d = m[4]
  if d and d.conceal and d.conceal ~= "" then
    conceals[#conceals + 1] = d.conceal
  end
end
table.sort(conceals)
assert(
  #conceals == 4,
  "expected 4 conceal extmarks (\\alpha, \\beta, \\gamma, \\to), got "
    .. #conceals
    .. ": "
    .. table.concat(conceals, ",")
)
local seen = table.concat(conceals, ",")
assert(seen:find("α", 1, true), "α expected: " .. seen)
assert(seen:find("β", 1, true), "β expected: " .. seen)
assert(seen:find("γ", 1, true), "γ expected: " .. seen)
assert(seen:find("→", 1, true), "→ expected: " .. seen)

local function count(b)
  return #vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, {})
end

-- Detach stops re-decoration on later edits; re-attach works again.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x \\alpha y" })
  ent.attach(b)
  vim.wait(50)
  assert(count(b) == 1, "attached: " .. count(b))
  ent.detach(b)
  assert(count(b) == 0, "detach clears marks: " .. count(b))
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x \\beta y" })
  vim.wait(50)
  assert(count(b) == 0, "detached buffer must not be re-decorated; got " .. count(b))
  ent.attach(b)
  vim.wait(50)
  assert(count(b) == 1, "re-attached: " .. count(b))
end

-- toggle(0) acts on the current buffer, not on a slot keyed by 0.
do
  local b2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b2)
  vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "\\gamma" })
  ent.toggle(0)
  vim.wait(50)
  assert(count(b2) == 1, "first toggle attaches: " .. count(b2))
  local b3 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b3)
  vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "\\delta" })
  ent.toggle(0)
  vim.wait(50)
  assert(count(b3) == 1, "toggle in a second buffer attaches it: " .. count(b3))
  assert(count(b2) == 1, "first buffer stays attached: " .. count(b2))
  ent.toggle(0)
  vim.wait(50)
  assert(count(b3) == 0, "second toggle detaches: " .. count(b3))
end

-- `\alpha{}` conceals the braces along with the name.
do
  local b4 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b4, 0, -1, false, { "a\\alpha{}b \\beta{c}" })
  ent.attach(b4)
  vim.wait(50)
  local ms = vim.api.nvim_buf_get_extmarks(b4, NS, 0, -1, { details = true })
  assert(#ms == 2, "two marks: " .. #ms)
  assert(ms[1][3] == 1 and ms[1][4].end_col == 9, "braces concealed: " .. vim.inspect(ms[1]))
  assert(
    ms[2][3] == 11 and ms[2][4].end_col == 16,
    "brace with content kept: " .. vim.inspect(ms[2])
  )
end

io.write("entities ok\n")
os.exit(0)
