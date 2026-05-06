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
        and (not filt.file_path or r.file_path == filt.file_path)
        and (not filt.has_id or r.id)
      then
        out[#out + 1] = r
      end
    end
    return out
  end,
  links_to = function(_id)
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

vim.fn.delete("/tmp/lsp", "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("lsp_handlers_test: PASS")
