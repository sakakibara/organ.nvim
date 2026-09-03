-- In-process LSP server: handler-level tests.
-- We invoke handlers directly (without spinning up the rpc loop) so
-- the assertions are deterministic and fast.
--
-- Run via: nvim --headless -l tests/lsp_handlers_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Minimal in-memory query stub used by some handlers.
local SAMPLE_HEADLINES = {
  {
    id = "id-alpha",
    title = "Alpha",
    file_path = "/tmp/lsp/foo.org",
    line_start = 0,
    todo_state = "TODO",
    priority = "A",
    tags = { "work" },
  },
  {
    id = "id-beta",
    title = "Beta",
    file_path = "/tmp/lsp/foo.org",
    line_start = 5,
    todo_state = "DONE",
    tags = { "work" },
  },
  {
    id = "id-gamma",
    title = "Gamma",
    file_path = "/tmp/lsp/bar.org",
    line_start = 0,
    todo_state = "TODO",
    tags = { "home" },
  },
}
package.loaded["organ.query"] = {
  headlines = function(filt)
    filt = filt or {}
    local out = {}
    for _, r in ipairs(SAMPLE_HEADLINES) do
      if
        (not filt.id or r.id == filt.id)
        and (not filt.title or r.title == filt.title)
        and (not filt.title_match or r.title:find(filt.title_match, 1, true) ~= nil)
        and (not filt.file or r.file_path == filt.file)
        and (not filt.has_id or r.id)
      then
        out[#out + 1] = r
      end
    end
    return out
  end,
  -- Rows carry the source file under `source_headline`, like the real
  -- query builder.  Records the id asked for.
  links_to = function(id)
    _G.LINKS_TO_ASKED = id
    if id == "id-gamma" then
      return {
        {
          line = 8,
          target = id,
          source_headline = { file_path = "/tmp/lsp/foo.org", line_start = 5 },
        },
      }
    end
    return {}
  end,
  files = function()
    return {
      { file_path = "/tmp/lsp/foo.org" },
      { file_path = "/tmp/lsp/bar.org" },
    }
  end,
  agenda = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp/lsp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

local lsp = require("organ.lsp")
local H = lsp._handlers

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Set up a fixture buffer so handlers that read live buffer contents
-- have something to work with.
vim.fn.mkdir("/tmp/lsp", "p")
local fixture = "/tmp/lsp/foo.org"
vim.fn.writefile({
  "* TODO Alpha :work:",
  "  Body line A1",
  "  Body line A2",
  "** NEXT Sub-of-alpha",
  "   Sub body",
  "* DONE Beta :work:",
  "  Body of beta",
  "  See [[id:id-alpha]] and [[*Gamma]] and [[id:nonexistent]].",
  ":PROPERTIES:",
  ":FOO: bar",
  ":END:",
}, fixture)
local bufnr = vim.fn.bufadd(fixture)
vim.fn.bufload(bufnr)
vim.bo[bufnr].filetype = "org"

local URI = vim.uri_from_fname(fixture)

-- 1. documentSymbol: builds a hierarchy from buffer.
local syms = H["textDocument/documentSymbol"]({ textDocument = { uri = URI } })
check(
  "documentSymbol: 2 top-level (Alpha, Beta)",
  #syms == 2 and syms[1].name == "Alpha" and syms[2].name == "Beta",
  "got " .. vim.inspect(vim.tbl_map(function(s)
    return s.name
  end, syms))
)
check(
  "documentSymbol: Alpha has child Sub-of-alpha",
  #syms[1].children == 1 and syms[1].children[1].name == "Sub-of-alpha"
)
check("documentSymbol: TODO state in detail", syms[1].detail == "TODO" and syms[2].detail == "DONE")
check(
  "documentSymbol: Alpha range covers its subtree",
  syms[1].range["end"].line == syms[2].range.start.line - 1,
  "Alpha end="
    .. tostring(syms[1].range["end"].line)
    .. " Beta start="
    .. tostring(syms[2].range.start.line)
)

-- 2. workspace/symbol: cross-file fuzzy match.
local ws = H["workspace/symbol"]({ query = "amma" })
check("workspace/symbol query='amma': 1 match (Gamma)", #ws == 1 and ws[1].name == "Gamma")

local ws_all = H["workspace/symbol"]({ query = "" })
check("workspace/symbol query='': returns all 3", #ws_all == 3)

-- 3. definition: link → target.
-- Line 8 has [[id:id-alpha]] and [[*Gamma]]; cursor on each.
local def_id = H["textDocument/definition"]({
  textDocument = { uri = URI },
  position = { line = 7, character = 12 }, -- inside [[id:id-alpha]]
})
check(
  "definition: id:id-alpha → Alpha line 0",
  def_id and def_id.range.start.line == 0,
  "got " .. vim.inspect(def_id)
)

-- Locate the *Gamma link's column.
local line8 = vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1]
local g_start = line8:find("%[%[%*Gamma")
local def_title = H["textDocument/definition"]({
  textDocument = { uri = URI },
  position = { line = 7, character = g_start },
})
check(
  "definition: *Gamma → Gamma line 0",
  def_title
    and def_title.range.start.line == 0
    and def_title.uri == vim.uri_from_fname("/tmp/lsp/bar.org"),
  "got " .. vim.inspect(def_title)
)

-- 4. hover: shows headline preview.
local hover = H["textDocument/hover"]({
  textDocument = { uri = URI },
  position = { line = 7, character = 12 },
})
check(
  "hover on id:id-alpha returns markdown",
  hover and hover.contents.kind == "markdown" and hover.contents.value:find("Alpha") ~= nil,
  hover and hover.contents.value or "nil"
)

-- 5. completion: TODO context — fresh `* ` (empty partial) lists ALL
-- keywords; `* T` narrows to TODO only.
vim.fn.appendbufline(bufnr, "$", { "* " })
local last_line = vim.api.nvim_buf_line_count(bufnr)
vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_win_set_cursor(0, { last_line, 2 }) -- right after `* `
local comp = H["textDocument/completion"]({
  textDocument = { uri = URI },
  position = { line = last_line - 1, character = 2 },
})
local has_todo, has_next = false, false
for _, it in ipairs(comp.items) do
  if it.label == "TODO" then
    has_todo = true
  end
  if it.label == "NEXT" then
    has_next = true
  end
end
check("completion empty-partial: TODO + NEXT both present", has_todo and has_next)

vim.api.nvim_buf_set_lines(bufnr, last_line - 1, last_line, false, { "* T" })
vim.api.nvim_win_set_cursor(0, { last_line, 3 })
local comp_t = H["textDocument/completion"]({
  textDocument = { uri = URI },
  position = { line = last_line - 1, character = 3 },
})
local t_only = true
for _, it in ipairs(comp_t.items) do
  if it.label == "NEXT" then
    t_only = false
  end
end
check("completion 'T' partial: NEXT filtered out", t_only)

-- Clean up the appended line.
vim.api.nvim_buf_set_lines(bufnr, last_line - 1, last_line, false, {})

-- 5b. completion: src_block language slot — `#+begin_src ` (empty
-- partial) lists languages; `#+begin_src ba` narrows to bash.
vim.fn.appendbufline(bufnr, "$", { "#+begin_src " })
last_line = vim.api.nvim_buf_line_count(bufnr)
vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_win_set_cursor(0, { last_line, 12 }) -- right after the space
local comp_sl = H["textDocument/completion"]({
  textDocument = { uri = URI },
  position = { line = last_line - 1, character = 12 },
})
local has_bash, has_lua = false, false
for _, it in ipairs(comp_sl.items) do
  if it.label == "bash" then
    has_bash = true
  end
  if it.label == "lua" then
    has_lua = true
  end
end
check("completion src_lang: bash + lua present", has_bash and has_lua)

vim.api.nvim_buf_set_lines(bufnr, last_line - 1, last_line, false, { "#+begin_src ba" })
vim.api.nvim_win_set_cursor(0, { last_line, 14 })
local comp_sl_ba = H["textDocument/completion"]({
  textDocument = { uri = URI },
  position = { line = last_line - 1, character = 14 },
})
local ba_only_bash = true
for _, it in ipairs(comp_sl_ba.items) do
  if it.label == "lua" then
    ba_only_bash = false
  end
end
check("completion src_lang 'ba' filters out lua", ba_only_bash)

vim.api.nvim_buf_set_lines(bufnr, last_line - 1, last_line, false, {})

-- 6. rename: produces edits for the headline + reference link.
local ren = H["textDocument/rename"]({
  textDocument = { uri = URI },
  position = { line = 0, character = 0 },
  newName = "AlphaPrime",
})
check("rename: returns changes table", type(ren) == "table" and ren.changes)
local edits_for_foo = ren.changes[URI] or {}
check("rename: at least one edit on Alpha's own file", #edits_for_foo >= 1)

-- 7. codeAction: on a headline.
local actions = H["textDocument/codeAction"]({
  textDocument = { uri = URI },
  range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
})
check(
  "codeAction on headline: includes Promote subtree",
  vim.iter and vim.iter(actions):any(function(a)
      return a.title:find("Promote")
    end)
    or (function()
      for _, a in ipairs(actions) do
        if a.title:find("Promote") then
          return true
        end
      end
      return false
    end)()
)

-- 8. foldingRange: every headline produces a fold.
local folds = H["textDocument/foldingRange"]({ textDocument = { uri = URI } })
check("foldingRange: at least 2 headline regions", #folds >= 2)
-- Drawer fold for the PROPERTIES drawer.
local has_drawer_fold = false
for _, f in ipairs(folds) do
  -- :PROPERTIES: is on line 9 (0-indexed 8); :END: on line 11 (0-indexed 10).
  if f.startLine == 8 and f.endLine == 10 then
    has_drawer_fold = true
  end
end
check("foldingRange: drawer fold (8..10)", has_drawer_fold)

-- 9. documentLink: 3 links in the buffer.
local links = H["textDocument/documentLink"]({ textDocument = { uri = URI } })
check("documentLink: 3 links found (id-alpha, Gamma, nonexistent)", #links == 3, "got " .. #links)

-- 10. diagnostic: the [[id:nonexistent]] link is broken.
local diag = H["textDocument/diagnostic"]({ textDocument = { uri = URI } })
check("diagnostic: returns full kind", diag.kind == "full" and type(diag.items) == "table")
local has_broken = false
for _, d in ipairs(diag.items) do
  if d.message:find("nonexistent") then
    has_broken = true
  end
end
check(
  "diagnostic: flags [[id:nonexistent]] as broken",
  has_broken,
  "got items: " .. vim.inspect(diag.items)
)

-- 11. references: headline at row 0 (Alpha) — ID lookup runs even if
-- empty list comes back.
local refs = H["textDocument/references"]({
  textDocument = { uri = URI },
  position = { line = 0, character = 5 },
})
check("references: returns table (may be empty under stub)", type(refs) == "table")

-- 12. Handlers scope headline lookups to the requesting document with
-- the `file` filter (the key the query builder honours).  bar.org holds
-- only Gamma at row 0; foo.org's Alpha also sits at row 0.
local BAR_URI = vim.uri_from_fname("/tmp/lsp/bar.org")
_G.LINKS_TO_ASKED = nil
local bar_refs = H["textDocument/references"]({
  textDocument = { uri = BAR_URI },
  position = { line = 0, character = 2 },
})
check(
  "references: resolves the headline in the requesting file",
  _G.LINKS_TO_ASKED == "id-gamma",
  "asked for " .. tostring(_G.LINKS_TO_ASKED)
)
check(
  "references: id-link rows use the source headline's file",
  bar_refs[1] and bar_refs[1].uri == URI and bar_refs[1].range.start.line == 7,
  vim.inspect(bar_refs)
)
local bar_syms = H["textDocument/documentSymbol"]({ textDocument = { uri = BAR_URI } })
check(
  "documentSymbol (unloaded file): only that file's headlines",
  #bar_syms == 1 and bar_syms[1].name == "Gamma",
  vim.inspect(bar_syms)
)

-- 13. Symbol kinds follow the EFFECTIVE todo sequences (annotations
-- stripped): DONE is a done-set keyword -> Constant (14).
do
  local saved_seq = require("organ").config.todo.sequence
  require("organ").config.todo.sequence = { "TODO(t)", "NEXT(n)", "|", "DONE(d)" }
  local syms_ann = H["textDocument/documentSymbol"]({ textDocument = { uri = URI } })
  local beta
  for _, s in ipairs(syms_ann) do
    if s.name == "Beta" then
      beta = s
    end
  end
  check(
    "documentSymbol: DONE headline is Constant under an annotated sequence",
    beta and beta.kind == 14,
    beta and ("kind=" .. beta.kind)
  )
  require("organ").config.todo.sequence = saved_seq
end

-- 14. definition: `file:` links resolve against the document's directory.
vim.fn.mkdir("/tmp/lsp/sub", "p")
local rel_src = "/tmp/lsp/sub/src.org"
vim.fn.writefile({ "* S", "see [[file:target.org][t]]" }, rel_src)
local rel_bufnr = vim.fn.bufadd(rel_src)
vim.fn.bufload(rel_bufnr)
local def_file = H["textDocument/definition"]({
  textDocument = { uri = vim.uri_from_fname(rel_src) },
  position = { line = 1, character = 8 },
})
check(
  "definition: file:target.org resolves next to the document",
  def_file and def_file.uri == vim.uri_from_fname("/tmp/lsp/sub/target.org"),
  def_file and def_file.uri
)

-- 14b. definition: `file:path::*Heading` lands on the headline whose
-- title is exactly the anchor, and `./` in the path is normalised.
do
  local n = #SAMPLE_HEADLINES
  SAMPLE_HEADLINES[n + 1] =
    { id = "id-top", title = "Top", file_path = "/tmp/lsp/sub/t.org", line_start = 0 }
  SAMPLE_HEADLINES[n + 2] =
    { id = "id-header", title = "Header", file_path = "/tmp/lsp/sub/t.org", line_start = 1 }
  SAMPLE_HEADLINES[n + 3] =
    { id = "id-head", title = "Head", file_path = "/tmp/lsp/sub/t.org", line_start = 2 }
  local anchor_src = "/tmp/lsp/sub/src2.org"
  vim.fn.writefile({ "* S", "see [[file:./t.org::*Head][t]]" }, anchor_src)
  local anchor_bufnr = vim.fn.bufadd(anchor_src)
  vim.fn.bufload(anchor_bufnr)
  local def_anchor = H["textDocument/definition"]({
    textDocument = { uri = vim.uri_from_fname(anchor_src) },
    position = { line = 1, character = 8 },
  })
  check(
    "definition: file:./t.org::*Head normalises the path",
    def_anchor and def_anchor.uri == vim.uri_from_fname("/tmp/lsp/sub/t.org"),
    def_anchor and def_anchor.uri
  )
  check(
    "definition: file:./t.org::*Head lands on the exact title",
    def_anchor and def_anchor.range.start.line == 2,
    def_anchor and ("line " .. tostring(def_anchor.range.start.line))
  )
  for _ = 1, 3 do
    table.remove(SAMPLE_HEADLINES)
  end
end

-- 15. foldingRange: a block's closing line belongs to its fold.
local blocks_path = "/tmp/lsp/blocks.org"
vim.fn.writefile({
  "* H",
  "#+begin_src lua",
  "print(1)",
  "#+end_src",
  "text",
  ":PROPERTIES:",
  ":ID: y",
  ":END:",
  "tail",
}, blocks_path)
local blocks_bufnr = vim.fn.bufadd(blocks_path)
vim.fn.bufload(blocks_bufnr)
local block_folds =
  H["textDocument/foldingRange"]({ textDocument = { uri = vim.uri_from_fname(blocks_path) } })
local src_fold, drawer_fold
for _, f in ipairs(block_folds) do
  if f.startLine == 1 then
    src_fold = f
  elseif f.startLine == 5 then
    drawer_fold = f
  end
end
check(
  "foldingRange: src block fold ends on #+end_src (line 3)",
  src_fold and src_fold.endLine == 3,
  src_fold and ("endLine=" .. src_fold.endLine)
)
check(
  "foldingRange: drawer fold ends on :END: (line 7)",
  drawer_fold and drawer_fold.endLine == 7,
  drawer_fold and ("endLine=" .. drawer_fold.endLine)
)

vim.fn.delete("/tmp/lsp", "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("lsp_handlers_test: PASS")
