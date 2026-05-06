-- ftplugin/subtree.lua keymaps execute the corresponding subtree
-- operation when fired in an org buffer.  Each binding listed in
-- `structure.keymaps` defaults must mutate the buffer as advertised.
--
-- Run via: nvim --headless -l tests/ftplugin_subtree_keys_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

require("organ").setup({
  org_dir = vim.fn.tempname(),
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  -- Use the documented defaults so the test mirrors a real install.
  structure = { enabled = true },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Build a fresh org buffer with two top-level subtrees, attach the
-- subtree ftplugin, position the cursor on the second heading, and
-- return the buffer + the lhs of the binding for `key`.
local function setup(key_in_cfg)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Alpha",
    "  body of alpha",
    "* Beta",
    "  body of beta",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- on "* Beta"
  require("organ.ftplugin.subtree").attach(b)
  local cfg = (require("organ").config.structure or {}).keymaps or {}
  return b, cfg[key_in_cfg]
end

-- Find the buffer-local n-mode keymap callback for `lhs` and call it.
local function fire(b, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
    if m.lhs == lhs and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- ---------------------------------------------------------------------------
-- (a) move_subtree_up: <M-k> swaps "* Beta" with "* Alpha".
-- ---------------------------------------------------------------------------
do
  local b, lhs = setup("move_subtree_up")
  if not lhs then
    fails = fails + 1
    print("FAIL  move_subtree_up: no lhs configured in defaults")
  else
    check("move_subtree_up: keymap installed", fire(b, lhs))
    local out = lines(b)
    check(
      "move_subtree_up: '* Beta' moved above '* Alpha'",
      out[1] == "* Beta" and out[3] == "* Alpha",
      vim.inspect(out)
    )
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ---------------------------------------------------------------------------
-- (b) move_subtree_down: when on the FIRST heading, <M-j> swaps it down.
-- ---------------------------------------------------------------------------
do
  local b, lhs = setup("move_subtree_down")
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on "* Alpha"
  if not lhs then
    fails = fails + 1
    print("FAIL  move_subtree_down: no lhs configured in defaults")
  else
    check("move_subtree_down: keymap installed", fire(b, lhs))
    local out = lines(b)
    check(
      "move_subtree_down: '* Alpha' moved below '* Beta'",
      out[1] == "* Beta" and out[3] == "* Alpha",
      vim.inspect(out)
    )
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ---------------------------------------------------------------------------
-- (c) demote_subtree: cursor on "* Beta" → "** Beta".
-- ---------------------------------------------------------------------------
do
  local b, lhs = setup("demote_subtree")
  if not lhs then
    fails = fails + 1
    print("FAIL  demote_subtree: no lhs configured in defaults")
  else
    fire(b, lhs)
    local out = lines(b)
    check("demote_subtree: '* Beta' became '** Beta'", out[3] == "** Beta", vim.inspect(out))
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ---------------------------------------------------------------------------
-- (d) promote_subtree: '** Beta' back to '* Beta'.
-- ---------------------------------------------------------------------------
do
  local b, lhs = setup("promote_subtree")
  if not lhs then
    fails = fails + 1
    print("FAIL  promote_subtree: no lhs configured in defaults")
  else
    -- First demote so there's something to promote.
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {
      "* Alpha",
      "** Beta",
      "  body",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on "** Beta"
    fire(b, lhs)
    local out = lines(b)
    check("promote_subtree: '** Beta' became '* Beta'", out[2] == "* Beta", vim.inspect(out))
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ---------------------------------------------------------------------------
-- (e) meta_return: opens a new same-level heading below the cursor's heading.
-- ---------------------------------------------------------------------------
do
  local b, lhs = setup("meta_return")
  if not lhs then
    fails = fails + 1
    print("FAIL  meta_return: no lhs configured in defaults")
  else
    fire(b, lhs)
    local out = lines(b)
    -- meta_return inserts a new "* " line (sibling) somewhere after Beta.
    local found = false
    for i, l in ipairs(out) do
      if l == "* " and i > 3 then
        found = true
        break
      end
    end
    check("meta_return: new sibling heading inserted", found, vim.inspect(out))
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ftplugin_subtree_keys_test: PASS")
