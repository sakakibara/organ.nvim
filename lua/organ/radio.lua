-- Editor-side radio links: highlight + follow.  Reuses the matcher and
-- target normalization from `organ.ast.radio` (the export-side core) so
-- the buffer view agrees with what export resolves.  Distinct from
-- `organ.ast.radio`: this module is buffer/tree-based, that one is AST.

local ast_radio = require("organ.ast.radio")

local M = {}

-- Per-buffer definitions cache, rebuilt when changedtick advances.
local _cache = {}

-- Scan all buffer lines for <<<phrase>>> definitions.  Returns the raw
-- phrase list and a map phrase:lower() -> { line (1-based), col (0-based) }
-- of the first definition (for follow to jump to).
local function scan_defs(bufnr)
  local raw, defs = {}, {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local pos = 1
    while true do
      local s, e, phrase = line:find("<<<(.-)>>>", pos)
      if not s then
        break
      end
      if phrase:match("%S") then
        raw[#raw + 1] = phrase
        local key = phrase:lower()
        if not defs[key] then
          defs[key] = { line = i, col = s - 1 }
        end
      end
      pos = e + 1
    end
  end
  return raw, defs
end

-- Cache entry for bufnr, rebuilt on changedtick.
function M.targets(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return { phrases = {}, defs = {}, matcher = ast_radio.build_matcher({}) }
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = _cache[bufnr]
  if c and c.tick == tick then
    return c
  end
  local raw, defs = scan_defs(bufnr)
  local phrases = ast_radio.normalize_targets(raw)
  c = {
    tick = tick,
    phrases = phrases,
    defs = defs,
    matcher = ast_radio.build_matcher(phrases),
  }
  _cache[bufnr] = c
  return c
end

function M.invalidate(bufnr)
  _cache[bufnr or vim.api.nvim_get_current_buf()] = nil
end

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = vim.api.nvim_create_augroup("organ_radio_cache", { clear = true }),
  callback = function(ev)
    _cache[ev.buf] = nil
  end,
})

return M
