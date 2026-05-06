-- Verifies organ.image link-target resolution and is_image_path.
-- Run via: nvim --headless -l tests/image_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local img = require("organ.image")

-- 1. is_image_path picks up common extensions.
assert(img._is_image_path("/tmp/foo.png"))
assert(img._is_image_path("foo.JPG"))
assert(img._is_image_path("/a/b/c.svg"))
assert(not img._is_image_path("/tmp/foo.txt"))
assert(not img._is_image_path(nil))
assert(not img._is_image_path(""))

local function setup_buf(line, col, file_name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_set_current_buf(buf)
  if file_name then
    vim.api.nvim_buf_set_name(buf, file_name)
  end
  vim.api.nvim_win_set_cursor(0, { 1, col })
  return buf
end

-- 2. file: link with absolute path.
do
  setup_buf("see [[file:/tmp/x.png][img]]", 8)
  local t = img._link_target_at_cursor(0)
  assert(t == "/tmp/x.png", "expected /tmp/x.png, got " .. tostring(t))
end

-- 3. plain bracket link with home-relative path.
do
  setup_buf("ref [[~/img/foo.jpg]]", 6)
  local t = img._link_target_at_cursor(0)
  assert(
    t and t:sub(-#"img/foo.jpg") == "img/foo.jpg",
    "expected expanded ~ path, got " .. tostring(t)
  )
  assert(not t:find("^~"), "tilde should be expanded")
end

-- 4. relative path resolved against the current file's dir.
do
  setup_buf("ref [[./pic.png]]", 6, "/tmp/sub/note.org")
  local t = img._link_target_at_cursor(0)
  -- Relative paths may be resolved with or without the './' segment;
  -- accept both variants — we just need a path under /tmp/sub/.
  assert(
    t == "/tmp/sub/pic.png" or t == "/tmp/sub/./pic.png",
    "expected pic.png under /tmp/sub/, got " .. tostring(t)
  )
end

-- 5. Cursor outside any link returns nil.
do
  setup_buf("just text no link", 5)
  assert(img._link_target_at_cursor(0) == nil)
end

io.write("image ok\n")
os.exit(0)
