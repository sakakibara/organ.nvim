-- New link protocols + abbreviated #+LINK + ::/regex/ search option.
-- Run via: nvim --headless -l tests/link_protocols_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local link = require("organ.link")

-- doi: → synthesised https URL.
local k, t = link.resolve("doi:10.1109/5.771073")
assert(k == "url_synth", "doi: kind: " .. k)
assert(t == "https://doi.org/10.1109/5.771073", "doi target: " .. t)

-- man: / info: / help: kept as scheme-typed; URL_SCHEMES untouched.
assert(select(1, link.resolve("man:bash")) == "man", "man:")
assert(select(1, link.resolve("info:emacs")) == "info", "info:")
assert(select(1, link.resolve("help:vim")) == "help", "help:")
assert(select(1, link.resolve("ftp://x")) == "ftp", "ftp scheme")
assert(select(1, link.resolve("tel:+1234")) == "tel", "tel scheme")

-- elisp: / shell: bubble through resolve as their own kinds; gated at dispatch.
assert(select(1, link.resolve('elisp:(message "hi")')) == "elisp", "elisp resolve")
assert(select(1, link.resolve("shell:rm -rf /")) == "shell", "shell resolve")

-- elisp:/shell: action gated unless allow_unsafe = true; default config rejects.
local action = link.open("shell:echo hello")
assert(action.kind == "unsafe", "shell action.kind: " .. action.kind)

-- Abbrev expansion: #+LINK: gh https://github.com/%s
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([==[#+LINK: gh https://github.com/%s
#+LINK: search https://duckduckgo.com/?q=%h
* Headline
[[gh:torvalds/linux]]
[[search:org mode]]
]==])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

local abbrev = link.parse_abbrev(b)
assert(abbrev.gh == "https://github.com/%s", "abbrev gh: " .. tostring(abbrev.gh))
assert(
  abbrev.search == "https://duckduckgo.com/?q=%h",
  "abbrev search: " .. tostring(abbrev.search)
)

-- Resolve via abbrev returns the expanded URL.
local _, expanded = link.resolve("gh:torvalds/linux", { abbrev = abbrev })
assert(expanded == "https://github.com/torvalds/linux", "gh expansion: " .. tostring(expanded))

local _, expanded2 = link.resolve("search:org mode", { abbrev = abbrev })
-- vim.uri_encode encodes the space.
assert(
  expanded2:find("org%%20mode", 1) or expanded2:find("org+mode", 1, true),
  "search expansion should URL-encode space; got: " .. expanded2
)

-- file:::/regex/ search option is recognised by dispatch_edit_file via
-- the resolve anchor split (we test resolve here; dispatch is buffer-bound).
local kind, fpart, anchor = link.resolve("file:notes.org::/foo.*bar/")
assert(
  kind == "file" and fpart == "notes.org",
  "regex anchor parse: " .. tostring(kind) .. "/" .. tostring(fpart)
)
assert(anchor == "/foo.*bar/", "regex anchor: " .. tostring(anchor))

vim.fn.delete(tmp, "rf")
io.write("link protocols ok\n")
os.exit(0)
