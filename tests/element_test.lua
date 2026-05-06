-- element.lua: TS-driven element-at-cursor + headline / link extraction.
-- Run via: nvim --headless -l tests/element_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

-- Load both parsers (block + inline). Without org_inline, link nodes
-- aren't injected and we'd be testing only the block-grammar path.
local parser_path = require("organ.defaults").parser_path
local inline_path = (parser_path:gsub("/org%.so$", "/org_inline.so"))
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = inline_path })

local element = require("organ.element")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function with_buf(lines, fn)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  -- Force the parser to attach + parse.
  pcall(vim.treesitter.start, b, "org")
  element.invalidate(b)
  fn(b)
  vim.api.nvim_buf_delete(b, { force = true })
end

-- 1. parser_loaded gates correctly.
with_buf({ "* Heading" }, function(b)
  check("parser_loaded true when parser attached", element.parser_loaded(b) == true)
end)

-- 2. headline_at returns metadata for the enclosing headline.
with_buf({
  "* TODO Top   :work:urgent:",
  "  body",
  "** [#A] Sub",
  "   sub body",
  "* Other",
}, function(b)
  local h = element.headline_at(b, 1) -- in body of "Top"
  check("headline_at returns Top headline", h and h.title == "Top" and h.level == 1)
  check("headline_at extracts TODO", h and h.todo_state == "TODO")
  check(
    "headline_at extracts tags",
    h and #h.tags == 2 and h.tags[1] == "work" and h.tags[2] == "urgent"
  )
  local h2 = element.headline_at(b, 2) -- on the Sub heading
  check("headline_at level 2", h2 and h2.level == 2 and h2.title == "Sub")
  check("headline_at priority", h2 and h2.priority == "A")
  local h3 = element.headline_at(b, 3) -- in Sub's body
  check("headline_at descends to Sub from sub-body", h3 and h3.title == "Sub")
end)

-- 3. headlines() returns all in document order.
with_buf({
  "* H1",
  "** H1.1",
  "* H2",
  "** H2.1",
  "** H2.2",
}, function(b)
  local hs = element.headlines(b)
  check(
    "headlines: 5 in doc order",
    #hs == 5 and hs[1].title == "H1" and hs[5].title == "H2.2",
    "got " .. #hs .. ": " .. vim.inspect(vim.tbl_map(function(h)
      return h.title
    end, hs))
  )
  -- H1's subtree includes H1.1 (rows 0-1). line_end should be the
  -- last row of the subtree (1), not the heading line alone (0).
  check(
    "headlines: H1.line_end covers subtree (incl. H1.1)",
    hs[1].line_end == 1,
    "got " .. hs[1].line_end
  )
end)

-- 4. links: TS-driven; finds `[[...]]` only outside inert blocks.
with_buf({
  "* Heading",
  "Body with [[id:abc][see]] link.",
  "And another [[*Other][title]] one.",
  "#+begin_src lua",
  "-- [[id:in-src-block]] should NOT count",
  "#+end_src",
  "After src: [[id:after]] counts.",
}, function(b)
  local ls = element.links(b)
  -- 3 valid links (rows 1, 2, 6).
  check(
    "links: 3 found, src block link excluded",
    #ls == 3,
    "got " .. #ls .. ": " .. vim.inspect(vim.tbl_map(function(l)
      return l.target
    end, ls))
  )
  -- Check structure of first link.
  if ls[1] then
    check("links: first target is id:abc", ls[1].target == "id:abc")
    check("links: first description is 'see'", ls[1].description == "see")
    check("links: first kind is regular", ls[1].kind == "regular")
  end
end)

-- 5. link_at: cursor inside a link returns it; outside returns nil.
with_buf({
  "Some [[id:foo][bar]] text",
}, function(b)
  local line = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  local s = line:find("%[%[id:foo")
  local link = element.link_at(b, 0, s + 2) -- inside the link
  check(
    "link_at: inside link returns the link",
    link and link.target == "id:foo" and link.description == "bar",
    "got " .. vim.inspect(link)
  )
  local none = element.link_at(b, 0, 1) -- in "Some "
  check("link_at: outside link returns nil", none == nil)
end)

-- 6. in_inert_block: gating
with_buf({
  "* H",
  "Body",
  "#+begin_src python",
  "x = [[1, 2]]",
  "#+end_src",
}, function(b)
  -- Body line: not inert.
  check("in_inert_block: body line false", element.in_inert_block(b, 1, 0) == false)
  -- Inside src block.
  check("in_inert_block: inside src block true", element.in_inert_block(b, 3, 5) == true)
end)

-- 7. at(): walks up to meaningful kind, prefers inline over block.
with_buf({
  "* Heading",
  "Some text [[id:thing]] more.",
}, function(b)
  local line = vim.api.nvim_buf_get_lines(b, 1, 2, false)[1]
  local s = line:find("%[%[id:thing")
  local at_link = element.at(b, 1, s + 2)
  check(
    "at: cursor on link returns kind=link",
    at_link and at_link.kind == "link",
    "got " .. vim.inspect(at_link and at_link.kind)
  )
  local at_para = element.at(b, 1, 1) -- in "Some text"
  check(
    "at: cursor in plain text returns paragraph or emphasis kind",
    at_para
      and (
        at_para.kind == "paragraph"
        or at_para.kind == "emphasis"
        or at_para.kind == "verbatim"
        or at_para.kind == "section"
        or at_para.kind == "headline"
      )
  )
  local at_hl = element.at(b, 0, 2) -- on the `H` of "Heading"
  check(
    "at: cursor in headline title returns kind=title (most-specific node)",
    at_hl and (at_hl.kind == "title" or at_hl.kind == "headline_line" or at_hl.kind == "headline"),
    "got " .. (at_hl and at_hl.kind or "nil")
  )
end)

-- 8. in_tag_region: TS-aware (uses tag_list node).
with_buf({
  "* Heading :w",
}, function(b)
  -- Right after `:w` typed: cursor at col 13.
  -- Note: tag_list might not parse a partial tag, so test against
  -- a complete one + partial after colon.
  check("in_tag_region: false in headline body (col 2)", element.in_tag_region(b, 0, 2) == false)
end)

with_buf({
  "* Heading :work:",
}, function(b)
  -- col inside :work: section
  check("in_tag_region: true inside :work:", element.in_tag_region(b, 0, 13) == true)
end)

-- 9. in_headline_first_word: detect TODO completion context.
with_buf({
  "* T",
}, function(b)
  local ok, partial = element.in_headline_first_word(b, 0, 3)
  check("in_headline_first_word: true after `* T`", ok == true and partial == "T")
end)

with_buf({
  "Body line",
}, function(b)
  local ok = element.in_headline_first_word(b, 0, 4)
  check("in_headline_first_word: false on non-headline", ok == false)
end)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("element_test: PASS")
