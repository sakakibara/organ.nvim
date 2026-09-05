-- babel.tangle refuses to write over the org file it is tangling, however
-- the destination is spelled.  Emacs raises "Not allowed to tangle into
-- the same file as self" (ob-tangle.el); organ compares resolved absolute
-- paths so a symlink or a `..` route is caught too, which Emacs's plain
-- `expand-file-name` comparison misses.
-- Run via: nvim --headless -l tests/babel_tangle_self_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/sub", "p")

require("organ").setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local babel = require("organ.babel")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local SOURCE = table.concat({
  "Some prose before.",
  "",
  "* First heading",
  "Text under first.",
  "",
  "#+begin_src org :tangle %s",
  ",* tangled heading",
  "#+end_src",
  "",
  "* Second heading",
  "",
}, "\n")

local src_path = tmp .. "/notes.org"
vim.fn.system({ "ln", "-sf", "notes.org", tmp .. "/link.org" })

local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

-- Every spelling of "the file I am tangling".
local routes = {
  { "yes", "bare :tangle yes on an org block" },
  { "notes.org", "explicit basename" },
  { "./notes.org", "explicit ./ path" },
  { src_path, "absolute path" },
  { "sub/../notes.org", "path through .." },
  { "link.org", "symlink to the source" },
}

for _, route in ipairs(routes) do
  local spec, label = route[1], route[2]
  local text = SOURCE:format(spec)
  local fd = assert(io.open(src_path, "wb"))
  fd:write(text)
  fd:close()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, src_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))

  local ok, results = pcall(babel.tangle, bufnr)
  check(label .. ": tangle returns instead of throwing", ok, tostring(results))

  local after = read_file(src_path)
  check(label .. ": source file byte-unchanged", after == text, vim.inspect(after))

  if ok then
    local refused = false
    for _, r in pairs(results) do
      if not r.ok and tostring(r.error):find("same file as self", 1, true) then
        refused = true
      end
    end
    check(label .. ": refusal is reported", refused, vim.inspect(results))
  end

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- A block whose destination is a different file still tangles while a
-- sibling block aims at the source: refusing one target must not lose the
-- other's output.
do
  local out_path = tmp .. "/out.lua"
  local text = table.concat({
    "* Mixed",
    "#+begin_src org :tangle notes.org",
    ",* would clobber",
    "#+end_src",
    "",
    "#+begin_src lua :tangle " .. out_path,
    "print('kept')",
    "#+end_src",
    "",
  }, "\n")
  local fd = assert(io.open(src_path, "wb"))
  fd:write(text)
  fd:close()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, src_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
  babel.tangle(bufnr)
  check("mixed: source untouched", read_file(src_path) == text)
  check(
    "mixed: other target written",
    (read_file(out_path) or ""):find("print('kept')", 1, true) ~= nil
  )
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

if fails > 0 then
  io.write(("babel tangle self-target: %d failure(s)\n"):format(fails))
  os.exit(1)
end
io.write("babel tangle self-target ok\n")
