-- Grammar node coverage: assert that every structural element exposed
-- by the new tree-sitter-organ + tree-sitter-organ-inline grammars
-- shows up with the expected named children. Catches grammar
-- regressions independently of the indexer / LSP / consumer modules.
--
-- Run via: nvim --headless -l tests/grammar_nodes_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAITING", "|", "DONE", "CANCELLED" } },
})

local pp = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = pp })
vim.treesitter.language.add("org_inline", { path = (pp:gsub("/org%.so$", "/org_inline.so")) })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function parse_and_walk(text)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n"))
  vim.bo[b].filetype = "org"
  local parser = vim.treesitter.get_parser(b, "org")
  parser:parse(true)
  -- Collect every node type with its field accessors.
  local nodes_by_type = {}
  local function collect(parser_)
    for _, tree in ipairs(parser_:trees()) do
      local function visit(n)
        local t = n:type()
        nodes_by_type[t] = nodes_by_type[t] or {}
        nodes_by_type[t][#nodes_by_type[t] + 1] = n
        for c in n:iter_children() do
          visit(c)
        end
      end
      visit(tree:root())
    end
    for _, child in pairs(parser_:children()) do
      child:parse(true)
      collect(child)
    end
  end
  collect(parser)
  return b, nodes_by_type
end

local function field_text(node, name, b)
  local m = node:field(name)
  if not m or not m[1] then
    return nil
  end
  return vim.treesitter.get_node_text(m[1], b)
end

-- ── headline_line full decomposition ──────────────────────────────────
do
  local b, nodes = parse_and_walk("* TODO [#A] COMMENT Task title [33%] :work:urgent:\n")
  local hl = nodes.headline_line and nodes.headline_line[1]
  check("headline_line: present", hl ~= nil)
  if hl then
    check("headline_line: stars", field_text(hl, "stars", b) == "*")
    check("headline_line: todo", field_text(hl, "todo", b) == "TODO")
    check("headline_line: comment", field_text(hl, "comment", b) == "COMMENT")
    check("headline_line: priority", field_text(hl, "priority", b) == "[#A]")
    -- title may include trailing whitespace; cookie may include leading.
    -- Both are trimmed by consumers (e.g. element.parse_headline_node).
    check(
      "headline_line: title",
      (field_text(hl, "title", b) or ""):gsub("^%s+", ""):gsub("%s+$", "") == "Task title"
    )
    check("headline_line: cookie", (field_text(hl, "cookie", b) or ""):find("%[33%%%]") ~= nil)
    local tl = (hl:field("tag_list") or {})[1]
    local tags = {}
    if tl then
      for c in tl:iter_children() do
        if c:type() == "tag" then
          tags[#tags + 1] = vim.treesitter.get_node_text(c, b)
        end
      end
    end
    check("headline_line: tag children", #tags == 2 and tags[1] == "work" and tags[2] == "urgent")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── list_item: bullet + checkbox ─────────────────────────────────────
do
  local b, nodes = parse_and_walk("- [ ] todo\n- [x] done\n- [-] half\n- plain\n")
  check("list_item: 4 items", nodes.list_item and #nodes.list_item == 4)
  local cb = nodes.checkbox or {}
  check("list_item: 3 checkboxes", #cb == 3)
  check("list_item: bullet field present", nodes.bullet and #nodes.bullet == 4)
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── src_block: language + header_args ────────────────────────────────
do
  local b, nodes = parse_and_walk("#+begin_src lua :tangle x.lua\nprint('hi')\n#+end_src\n")
  local sb = nodes.src_block and nodes.src_block[1]
  check("src_block: present", sb ~= nil)
  if sb then
    check("src_block: language", field_text(sb, "language", b) == "lua")
    check("src_block: header_args", field_text(sb, "header_args", b) == ":tangle x.lua")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── keyword: name + value ────────────────────────────────────────────
do
  local b, nodes = parse_and_walk("#+title: My Doc\n")
  local k = nodes.keyword and nodes.keyword[1]
  check("keyword: present", k ~= nil)
  if k then
    check("keyword: name", field_text(k, "name", b) == "title")
    check("keyword: value", field_text(k, "value", b) == "My Doc")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── formula: #+TBLFM: separates from generic keyword ─────────────────
do
  local b, nodes = parse_and_walk("#+TITLE: Doc\n#+TBLFM: $3=$1+$2\n")
  local f = nodes.formula and nodes.formula[1]
  check("formula: present for #+TBLFM:", f ~= nil)
  if f then
    check("formula: name = TBLFM", field_text(f, "name", b) == "TBLFM")
    check("formula: value = $3=$1+$2", field_text(f, "value", b) == "$3=$1+$2")
  end
  -- #+TITLE: must NOT be a formula
  local k = nodes.keyword and nodes.keyword[1]
  check("formula: #+TITLE: stays as keyword", k ~= nil and field_text(k, "name", b) == "TITLE")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── comment_line + comment_body ──────────────────────────────────────
do
  local b, nodes = parse_and_walk("# first line\n#\n# third line\n")
  local cls = nodes.comment_line or {}
  check("comment_line: 3 lines parsed", #cls == 3)
  local bodies = nodes.comment_body or {}
  check("comment_line: bodies (skipping bare `#`)", #bodies == 2)
  if bodies[1] then
    check("comment_body: first content", field_text(cls[1], "body", b) == " first line")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── fixed_width_line + fixed_width_body ──────────────────────────────
do
  local b, nodes = parse_and_walk(": one\n:\n: three\n")
  local fls = nodes.fixed_width_line or {}
  check("fixed_width_line: 3 lines parsed", #fls == 3)
  local bodies = nodes.fixed_width_body or {}
  check("fixed_width_line: bodies (skipping bare `:`)", #bodies == 2)
  if bodies[1] then
    check("fixed_width_body: first content", field_text(fls[1], "body", b) == " one")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── timestamp injection: planning + clock ────────────────────────────
-- planning_timestamp / clock_timestamp ranges have org_inline injected,
-- so consumers see ts_date / ts_dayname / ts_time / ts_repeater /
-- ts_warning as named children.
do
  local b, nodes = parse_and_walk(
    "* H\nSCHEDULED: <2026-01-01 Mon 09:00 +1w -3d>\n"
      .. "CLOCK: [2026-01-01 Mon 09:00]--[2026-01-01 Mon 10:30] => 1:30\n"
  )
  check("planning_timestamp injection: ts_date", nodes.ts_date and #nodes.ts_date >= 1)
  check("planning_timestamp injection: ts_dayname", nodes.ts_dayname and #nodes.ts_dayname >= 1)
  check("planning_timestamp injection: ts_time", nodes.ts_time and #nodes.ts_time >= 1)
  check("planning_timestamp injection: ts_repeater", nodes.ts_repeater and #nodes.ts_repeater >= 1)
  check("planning_timestamp injection: ts_warning", nodes.ts_warning and #nodes.ts_warning >= 1)
  check(
    "planning_timestamp injection: timestamp_active",
    nodes.timestamp_active and #nodes.timestamp_active >= 1
  )
  -- clock_timestamp should yield inactive timestamps with their own ts_*
  check(
    "clock_timestamp injection: timestamp_inactive",
    nodes.timestamp_inactive and #nodes.timestamp_inactive >= 2
  )
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── property_drawer + node_property ──────────────────────────────────
do
  local b, nodes = parse_and_walk("* H\n:PROPERTIES:\n:ID: my-id\n:CUSTOM_ID: foo\n:END:\n")
  local props = nodes.node_property or {}
  check("node_property: 2 entries", #props == 2)
  if props[1] then
    check("node_property: name field", field_text(props[1], "name", b) == "ID")
    check("node_property: value field", field_text(props[1], "value", b) == "my-id")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── drawer name field ────────────────────────────────────────────────
do
  local b, nodes = parse_and_walk("* H\n:LOGBOOK:\nnote\n:END:\n")
  local d = nodes.drawer and nodes.drawer[1]
  check("drawer: present", d ~= nil)
  if d then
    check("drawer: name field", field_text(d, "name", b) == "LOGBOOK")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── planning + planning_entry ────────────────────────────────────────
do
  local b, nodes = parse_and_walk("* H\n  SCHEDULED: <2026-04-25 Sat> DEADLINE: <2026-04-30 Thu>\n")
  local entries = nodes.planning_entry or {}
  check("planning_entry: 2 (combined line)", #entries == 2)
  if entries[1] then
    check(
      "planning_entry[1]: keyword token is `[ws]*SCHEDULED:`",
      (field_text(entries[1], "keyword", b) or ""):match("^%s*([%w_%-]+):$") == "SCHEDULED"
    )
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── clock structure (closed, running) ────────────────────────────────
do
  local b, nodes = parse_and_walk(
    "* H\n:LOGBOOK:\nCLOCK: [2026-04-25 Sat 09:00]--[2026-04-25 Sat 10:30] => 1:30\nCLOCK: [2026-04-26 Sun 14:00]\n:END:\n"
  )
  local clocks = nodes.clock or {}
  check("clock: 2 entries", #clocks == 2)
  if clocks[1] then
    check("clock: start field present", (clocks[1]:field("start") or {})[1] ~= nil)
    check("clock: end field present (closed)", (clocks[1]:field("end") or {})[1] ~= nil)
    check("clock: duration field present (closed)", (clocks[1]:field("duration") or {})[1] ~= nil)
  end
  if clocks[2] then
    check("clock: running has no end", (clocks[2]:field("end") or {})[1] == nil)
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── footnote_definition + footnote_label ─────────────────────────────
do
  local b, nodes = parse_and_walk("[fn:my-note] body text\n")
  local fd = nodes.footnote_definition and nodes.footnote_definition[1]
  check("footnote_definition: present", fd ~= nil)
  if fd then
    check("footnote_definition: label", field_text(fd, "label", b) == "my-note")
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── table_header_row ─────────────────────────────────────────────────
do
  local b, nodes = parse_and_walk("| col1 | col2 |\n|------+------|\n| a    | b    |\n")
  check("table_header_row: present", nodes.table_header_row and #nodes.table_header_row == 1)
  check(
    "table_header_row: not also classified as table_row",
    not nodes.table_row or #nodes.table_row == 1
  ) -- only the body row
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── diary_sexp body (both forms) ─────────────────────────────────────
do
  local b, nodes = parse_and_walk("%%(diary-block 1 1 2026 12 31 2026)\n")
  local d = nodes.diary_sexp and nodes.diary_sexp[1]
  check("diary_sexp: bare form present", d ~= nil)
  if d then
    check("diary_sexp: body field", field_text(d, "body", b):find("diary%-block", 1, false) ~= nil)
  end
  vim.api.nvim_buf_delete(b, { force = true })
end
do
  local b, nodes = parse_and_walk("<%%(diary-cyclic 7 1 12 2025)>\n")
  local d = nodes.diary_sexp and nodes.diary_sexp[1]
  check("diary_sexp: <%%(...)> form present", d ~= nil)
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── inlinetask decomposition ─────────────────────────────────────────
do
  local b, nodes =
    parse_and_walk("* H\n*************** TODO Inline :tag:\n   body\n*************** END\n")
  local it = nodes.inlinetask and nodes.inlinetask[1]
  check("inlinetask: present", it ~= nil)
  local itl = nodes.inlinetask_line and nodes.inlinetask_line[1]
  check("inlinetask_line: present", itl ~= nil)
  if itl then
    check("inlinetask_line: todo", field_text(itl, "todo", b) == "TODO")
    check(
      "inlinetask_line: title",
      (field_text(itl, "title", b) or ""):gsub("%s+$", "") == "Inline"
    )
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ── inline grammar via injection ─────────────────────────────────────
do
  local b, nodes = parse_and_walk("Body with [[id:x][see]] and {{{macro(arg)}}} and [fn:1].\n")
  local lr = nodes.link_regular and nodes.link_regular[1]
  check("link_regular: present (via injection)", lr ~= nil)
  if lr then
    check("link_regular: target=id:x", field_text(lr, "target", b) == "id:x")
    check("link_regular: description=see", field_text(lr, "description", b) == "see")
  end
  local m = nodes.macro and nodes.macro[1]
  check("macro: name", m and field_text(m, "name", b) == "macro")
  local fr = nodes.footnote_ref and nodes.footnote_ref[1]
  check("footnote_ref: label=1", fr and field_text(fr, "label", b) == "1")
  vim.api.nvim_buf_delete(b, { force = true })
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("grammar_nodes_test: PASS")
