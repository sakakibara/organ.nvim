-- Buffer-level `#+KEYWORD: value` directive editing.

local M = {}

-- Locate the first `#+<NAME>:` line in `bufnr`.  Returns (lnum, line_text)
-- or nil.  Search is bounded to the first 200 lines — directives must
-- precede the first headline per org spec.
function M.find(bufnr, name)
  local n = math.min(200, vim.api.nvim_buf_line_count(bufnr))
  for i = 1, n do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local m = l:match("^%s*#%+([%w_]+):")
    if m and m:upper() == name:upper() then
      return i, l
    end
  end
  return nil
end

-- Set or insert `#+<name>: <value>`.  Updates an existing line in place;
-- otherwise inserts at the end of the leading directive block (after
-- any contiguous run of `#+...:` / blank lines, before the first body
-- content).
function M.set(bufnr, name, value)
  local idx = M.find(bufnr, name)
  local new_line = "#+" .. name .. ": " .. value
  if idx then
    vim.api.nvim_buf_set_lines(bufnr, idx - 1, idx, false, { new_line })
    return
  end
  local insert_at = 0
  local n = math.min(200, vim.api.nvim_buf_line_count(bufnr))
  for i = 1, n do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if l:match("^%s*#%+") or l:match("^%s*$") then
      insert_at = i
    else
      break
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { new_line })
end

local function notify_info(msg)
  if (require("organ").config or {}).notify then
    vim.schedule(function()
      require("organ.notify").info(msg)
    end)
  end
end

M.commands = {
  edit_todo_states = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local _, current = M.find(bufnr, "TODO")
      local prefill
      if current then
        prefill = current:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.*)$") or ""
      else
        local seq = (require("organ").config.todo or {}).sequence or {}
        prefill = table.concat(seq, " ")
      end
      vim.ui.input({ prompt = "TODO states: ", default = prefill }, function(value)
        if not value or value == "" then
          return
        end
        M.set(bufnr, "TODO", value)
        pcall(function()
          require("organ.highlights").register_buffer_todo_keywords(bufnr)
        end)
        notify_info("updated #+TODO: " .. value)
      end)
    end,
    desc = "Edit the buffer's `#+TODO:` directive via prompt; re-registers per-keyword highlights",
  },
  edit_tags = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local _, current = M.find(bufnr, "TAGS")
      local prefill = current and (current:match("^%s*#%+[Tt][Aa][Gg][Ss]:%s*(.*)$") or "") or ""
      vim.ui.input({ prompt = "Tags: ", default = prefill }, function(value)
        if not value or value == "" then
          return
        end
        M.set(bufnr, "TAGS", value)
        notify_info("updated #+TAGS: " .. value)
      end)
    end,
    desc = "Edit the buffer's `#+TAGS:` directive via prompt",
  },
}

return M
