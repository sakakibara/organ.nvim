-- protocol.parse / parse_query / handle dispatch.
-- Run via: nvim --headless -l tests/protocol_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local proto = require("organ.protocol")

-- 1. parse_query.
do
  local q = proto.parse_query("a=1&b=hello%20world&c=")
  assert(q.a == "1", "a: " .. tostring(q.a))
  assert(q.b == "hello world", "b: " .. tostring(q.b))
  assert(q.c == "", "c (empty): " .. tostring(q.c))
end

-- 2. parse: extract sub-protocol + params.
do
  local sub, params =
    proto.parse("org-protocol://capture?template=t&url=https%3A%2F%2Fx&title=A%20Title")
  assert(sub == "capture", "sub: " .. tostring(sub))
  assert(params.template == "t", "template: " .. tostring(params.template))
  assert(params.url == "https://x", "url: " .. tostring(params.url))
  assert(params.title == "A Title", "title: " .. tostring(params.title))
end

-- 3. parse: legacy single-slash form is also accepted.
do
  local sub, _ = proto.parse("org-protocol:/store-link?url=x&title=Y")
  assert(sub == "store-link", "legacy form sub: " .. tostring(sub))
end

-- 4. handle dispatches store-link → link_store.push (we observe via .list()).
do
  require("organ.link_store").clear()
  proto.handle("org-protocol://store-link?url=https%3A%2F%2Fexample.com&title=Example")
  local entries = require("organ.link_store").list()
  assert(#entries == 1, "expected 1 link in store; got " .. #entries)
  assert(entries[1].kind == "url", "kind: " .. tostring(entries[1].kind))
  assert(entries[1].url == "https://example.com", "url: " .. tostring(entries[1].url))
  assert(entries[1].title == "Example", "title: " .. tostring(entries[1].title))
end

-- 4b. A stored org-protocol link inserts as [[url][title]] (Emacs
-- `org-protocol-store-link` pushes `(url title)` onto `org-stored-links`).
do
  local store = require("organ.link_store")
  store.clear()
  store.push({ kind = "file_line", file_path = "/x/src.org", line = 2, title = "src.org:2" })
  proto.handle("org-protocol://store-link?url=https%3A%2F%2Fexample.com&title=Example")
  proto.handle("org-protocol://store-link?url=https%3A%2F%2Funtitled.example")

  local labels
  local saved_select = vim.ui.select
  vim.ui.select = function(items, _opts, cb)
    labels = items
    cb(items[2], 2)
  end
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "" })
  require("organ.link").insert_link()
  vim.ui.select = saved_select

  assert(
    vim.deep_equal(labels, { "https://untitled.example", "Example", "src.org:2" }),
    "labels: " .. vim.inspect(labels)
  )
  local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  assert(line == "[[https://example.com][Example]]", "inserted: " .. tostring(line))
end

-- 5. handle: capture stashes the body so the template can pull it.
do
  proto._captured_body = nil
  -- We don't actually trigger the capture flow here (would open UI); we just
  -- verify the body capture side-effect happens before dispatch.
  -- Stub capture.open so handle() doesn't error out.
  local capture_mod = require("organ.capture")
  local saved_open = capture_mod.open
  capture_mod.open = function(_) end
  proto.handle("org-protocol://capture?template=t&body=hello%20there")
  capture_mod.open = saved_open
  assert(proto.captured_body() == "hello there", "captured body should be readable once")
  assert(proto.captured_body() == "", "captured_body should clear after read")
end

-- 6. unknown sub-protocol is rejected gracefully (no throw).
do
  local ok = pcall(proto.handle, "org-protocol://unknown?foo=bar")
  assert(ok, "unknown sub should not throw")
end

-- 7. Malicious template name (vim command injection) is rejected.
-- Without validation, `template=default | qall!` would close nvim;
-- `template=foo<CR>!rm -rf ~` worse. Allowed chars: alnum, _, -.
do
  local captured = {}
  local capture_mod = require("organ.capture")
  local saved_open = capture_mod.open
  capture_mod.open = function(opts)
    captured[#captured + 1] = (opts and opts.key) or ""
  end

  proto.handle("org-protocol://capture?template=default") -- safe
  proto.handle("org-protocol://capture?template=default%20%7C%20qall%21") -- "default | qall!"
  proto.handle("org-protocol://capture?template=danger%3Cbar%3E") -- "danger<bar>"
  proto.handle("org-protocol://capture?template=%2Frm-rf") -- "/rm-rf"

  capture_mod.open = saved_open

  local saw_safe, saw_unsafe = false, false
  for _, key in ipairs(captured) do
    if key == "default" then
      saw_safe = true
    end
    if key:find("|", 1, true) or key:find("<", 1, true) or key:find("/", 1, true) then
      saw_unsafe = true
    end
  end
  assert(saw_safe, "safe template should reach capture.open")
  assert(
    not saw_unsafe,
    "unsafe template names must be rejected before reaching capture.open; got: "
      .. vim.inspect(captured)
  )
end

io.write("protocol ok\n")
os.exit(0)
