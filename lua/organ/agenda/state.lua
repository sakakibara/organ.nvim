-- Per-agenda-buffer view state stored in vim.b[bufnr].organ_agenda.
-- Encodes sparse-int-keyed tables as string keys for vim.b round-tripping.

local M = {}

-- vim.b serialises sparse-int-keyed Lua tables by padding gaps with vim.NIL.
-- Re-key block_starts and line_index as strings before storing, then decode
-- back to integers on read. Other state fields are dense or scalar -- safe.
local function encode(state)
  local enc = {}
  for k, v in pairs(state) do
    enc[k] = v
  end
  if state.block_starts then
    local s = {}
    for k, v in pairs(state.block_starts) do
      s[tostring(k)] = v
    end
    enc.block_starts = s
  end
  if state.line_index then
    local s = {}
    for k, v in pairs(state.line_index) do
      s[tostring(k)] = v
    end
    enc.line_index = s
  end
  return enc
end

local function decode(raw)
  if not raw then
    return {}
  end
  local dec = {}
  for k, v in pairs(raw) do
    dec[k] = v
  end
  if raw.block_starts then
    local s = {}
    for k, v in pairs(raw.block_starts) do
      s[tonumber(k) or k] = v
    end
    dec.block_starts = s
  end
  if raw.line_index then
    local s = {}
    for k, v in pairs(raw.line_index) do
      s[tonumber(k) or k] = v
    end
    dec.line_index = s
  end
  return dec
end

local function get(bufnr)
  return decode(vim.b[bufnr].organ_agenda)
end

local function set(bufnr, state)
  vim.b[bufnr].organ_agenda = encode(state)
end

M.encode = encode
M.decode = decode
M.get = get
M.set = set

return M
