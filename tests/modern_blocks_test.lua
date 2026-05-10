-- org-modern blocks: #+begin_*/#+end_* lines get virt_text overlay
-- decorating them with box drawing characters; the original text is
-- concealed.
-- Run via: nvim --headless -l tests/modern_blocks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = { blocks = true },
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "#+begin_src lua",
  "  print('hi')",
  "#+end_src",
  "",
  "#+begin_quote",
  "Some quote text.",
  "#+end_quote",
  "",
  "#+BEGIN_EXAMPLE",
  "verbatim text",
  "#+END_EXAMPLE",
})
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

local blocks = require("organ.modern.blocks")
blocks.attach(bufnr)
vim.wait(50) -- drain deferred initial apply

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local NS = vim.api.nvim_get_namespaces()["organ_modern_blocks"]
check("namespace registered", NS ~= nil)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

-- Marks: 3 begin lines + 3 end lines + 3 body lines = 9.  Body lines
-- get a `│ ` left side bar via inline virt_text; begin / end lines
-- get top / bottom overlay decoration.
check("9 extmarks placed (3 begin + 3 end + 3 body)", #marks == 9, "got " .. #marks)

-- Helper: find the mark on a given row.
local function mark_on(row)
  for _, m in ipairs(marks) do
    if m[2] == row then
      return m
    end
  end
end

local m_begin_src = mark_on(0)
check(
  "begin_src row has overlay virt_text",
  m_begin_src and m_begin_src[4] and m_begin_src[4].virt_text ~= nil
)
check(
  "begin_src virt_text contains '┌──'",
  (function()
    if not m_begin_src or not m_begin_src[4].virt_text then
      return false
    end
    for _, seg in ipairs(m_begin_src[4].virt_text) do
      if seg[1]:find("┌──", 1, true) then
        return true
      end
    end
    return false
  end)()
)
check(
  "begin_src virt_text contains the language label 'lua'",
  (function()
    if not m_begin_src or not m_begin_src[4].virt_text then
      return false
    end
    for _, seg in ipairs(m_begin_src[4].virt_text) do
      if seg[1] == "lua" then
        return true
      end
    end
    return false
  end)()
)

local m_end_src = mark_on(2)
check(
  "end_src virt_text contains '└──'",
  (function()
    if not m_end_src or not m_end_src[4].virt_text then
      return false
    end
    for _, seg in ipairs(m_end_src[4].virt_text) do
      if seg[1]:find("└──", 1, true) then
        return true
      end
    end
    return false
  end)()
)

-- Uppercase BEGIN_EXAMPLE matched too.
local m_uc = mark_on(8)
check("uppercase #+BEGIN_EXAMPLE recognised", m_uc ~= nil and m_uc[4] and m_uc[4].virt_text ~= nil)

-- conceallevel set.
check("conceallevel >= 2", vim.wo.conceallevel >= 2)

-- detach() removes them.
blocks.detach(bufnr)
local after = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
check("detach() clears marks", #after == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_blocks_test: PASS")
