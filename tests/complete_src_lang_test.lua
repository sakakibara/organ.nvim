-- src_block language completion: triggers when the cursor is in the
-- LANG slot of a `#+begin_src` line.  Run via:
--   nvim --headless -l tests/complete_src_lang_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local sl = require("organ.complete.src_lang")

local function buf(line)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
  return b
end

-- Triggers right after `#+begin_src ` (empty partial).
do
  local b = buf("#+begin_src ")
  local p = sl.cursor_partial(b, 1, 12)
  check("empty partial after fence", p == "", "got " .. vim.inspect(p))
end

-- Captures the partial language name.
do
  local b = buf("#+begin_src lu")
  local p = sl.cursor_partial(b, 1, 14)
  check("partial 'lu'", p == "lu", "got " .. vim.inspect(p))
end

-- Case-insensitive on the fence keyword (BEGIN_SRC).
do
  local b = buf("#+BEGIN_SRC ba")
  local p = sl.cursor_partial(b, 1, 14)
  check("partial 'ba' under uppercase fence", p == "ba", "got " .. vim.inspect(p))
end

-- Off when the cursor is BEFORE the language slot.
do
  local b = buf("#+begin_src lua")
  local p = sl.cursor_partial(b, 1, 5)
  check("nil mid-fence", p == nil, "got " .. vim.inspect(p))
end

-- Off when on a different line (no fence).
do
  local b = buf("just text")
  local p = sl.cursor_partial(b, 1, 4)
  check("nil on plain line", p == nil, "got " .. vim.inspect(p))
end

-- Empty partial returns the full language list.
do
  local items = sl.completion_items("")
  check("non-empty list for empty partial", #items > 5, "got " .. tostring(#items))
end

-- 'ba' filters to bash and similar.
do
  local items = sl.completion_items("ba")
  local names = {}
  for _, it in ipairs(items) do
    names[it.label] = true
  end
  check("'ba' includes bash", names.bash == true, "got " .. vim.inspect(vim.tbl_keys(names)))
end

-- 'XYZ' yields no match.
do
  local items = sl.completion_items("xyz")
  check("'xyz' returns no items", #items == 0, "got " .. tostring(#items))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("complete_src_lang_test: PASS")
os.exit(0)
