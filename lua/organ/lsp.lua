-- In-process LSP server for org files.
--
-- Implements the subset of LSP that maps cleanly to org semantics:
--
--   textDocument/documentSymbol     → headline outline (for aerial,
--                                     symbols-outline, telescope, etc.)
--   workspace/symbol                → cross-file headline search
--   textDocument/definition         → link → target
--   textDocument/references         → backlinks (ID + fuzzy title)
--   textDocument/hover              → link target preview
--   textDocument/completion         → unified completion (links, todos,
--                                     tags, directives, drawers, etc.)
--   textDocument/rename             → headline rename + cascade across
--                                     all referencing files
--   textDocument/codeAction         → context-aware menu (promote,
--                                     demote, refile, archive, etc.)
--   textDocument/foldingRange       → headline + drawer folds
--   textDocument/documentLink       → all `[[link]]`s as clickable
--   textDocument/diagnostic         → broken links, unresolved IDs
--   textDocument/formatting         → paragraph rewrap (also wired
--                                     into conform / vim.lsp.buf.format)
--   textDocument/rangeFormatting    → same, scoped to a visual range
--
-- Negotiates UTF-8 position encoding with the client so we can index
-- by byte columns (no UTF-16 conversion overhead). Routes through our
-- existing organ.query / organ.complete / organ.backlinks modules so
-- there's no duplicate logic.

local M = {}

local SERVER_NAME = "organ"
local clients_by_root = {} -- root_dir → client_id

-- ── helpers ───────────────────────────────────────────────────────────

local function uri_to_path(uri)
  return vim.uri_to_fname(uri)
end

local function path_to_uri(path)
  return vim.uri_from_fname(path)
end

-- 0-based LSP range from a row (1-based) and start/end byte columns.
local function lsp_range(row1, sc, row1_end, ec)
  return {
    start = { line = row1 - 1, character = sc },
    ["end"] = { line = (row1_end or row1) - 1, character = ec },
  }
end

-- Symbol kind constants per LSP spec (we only use a few).
local KIND = {
  File = 1,
  Module = 2,
  Namespace = 3,
  Package = 4,
  Class = 5,
  Method = 6,
  Property = 7,
  Field = 8,
  Constructor = 9,
  Enum = 10,
  Interface = 11,
  Function = 12,
  Variable = 13,
  Constant = 14,
  String = 15,
  Number = 16,
  Boolean = 17,
  Array = 18,
  Object = 19,
  Key = 20,
  Null = 21,
  EnumMember = 22,
  Struct = 23,
  Event = 24,
  Operator = 25,
  TypeParameter = 26,
}

-- Map TODO state → kind (visual hint in outline plugins).
local function todo_kind(todo_state)
  if not todo_state then
    return KIND.String
  end
  -- Treat done-set states as Constants (often greyed in outlines).
  local seq = require("organ.buf_config").read(nil, "todo.sequence") or {}
  local in_done = false
  for _, kw in ipairs(seq) do
    if kw == "|" then
      in_done = true
    elseif kw == todo_state and in_done then
      return KIND.Constant
    end
  end
  return KIND.Method
end

-- ── handlers ──────────────────────────────────────────────────────────

local handlers = {}

-- documentSymbol: hierarchical headline outline for the requested doc.
-- Uses tree-sitter so an unsaved buffer's edits show up immediately
-- (no DB round-trip).
handlers["textDocument/documentSymbol"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- Fall back to indexed data when buffer isn't loaded.
    local q = require("organ.query")
    local rows = q.headlines({ file_path = path })
    local symbols = {}
    for _, r in ipairs(rows) do
      symbols[#symbols + 1] = {
        name = r.title or "(untitled)",
        kind = todo_kind(r.todo_state),
        range = lsp_range((r.line_start or 0) + 1, 0, (r.line_end or r.line_start or 0) + 1, 0),
        selectionRange = lsp_range((r.line_start or 0) + 1, 0, (r.line_start or 0) + 1, 0),
        detail = r.todo_state,
      }
    end
    return symbols
  end

  -- TS-driven via element.lua: each headline is a parsed node with
  -- structured todo/priority/title/tags fields. Build the hierarchy
  -- from the flat list using level-based stack popping. Inlinetasks
  -- are merged in afterwards: each one nests under the headline whose
  -- subtree-range contains it.
  local element = require("organ.element")
  local hs = element.headlines(bufnr)
  local stack = {}
  local root = {}
  for _, h in ipairs(hs) do
    local title = (h.title and h.title ~= "") and h.title or "(untitled)"
    local sym = {
      name = title,
      detail = h.todo_state,
      kind = todo_kind(h.todo_state),
      range = lsp_range(h.line_start + 1, 0, (h.line_end or h.line_start) + 1, 0),
      selectionRange = lsp_range(h.line_start + 1, 0, h.line_start + 1, 0),
      children = {},
      _h_info = h, -- temp, used for inlinetask attachment
    }
    while #stack > 0 and stack[#stack].level >= h.level do
      table.remove(stack)
    end
    if #stack == 0 then
      root[#root + 1] = sym
    else
      table.insert(stack[#stack].sym.children, sym)
    end
    stack[#stack + 1] = { level = h.level, sym = sym }
  end

  -- Attach inlinetasks under their containing headline.
  for _, it in ipairs(element.inlinetasks(bufnr)) do
    local title = (it.title and it.title ~= "") and it.title or "(inlinetask)"
    local it_sym = {
      name = title,
      detail = it.todo_state and (it.todo_state .. "  (inline)") or "(inline)",
      kind = todo_kind(it.todo_state),
      range = lsp_range(it.line_start + 1, 0, (it.line_end or it.line_start) + 1, 0),
      selectionRange = lsp_range(it.line_start + 1, 0, it.line_start + 1, 0),
      children = {},
    }
    -- Find the deepest headline whose range contains this inlinetask.
    local function attach(node_list)
      for _, sym in ipairs(node_list) do
        local h = sym._h_info
        if
          h
          and it.line_start >= h.line_start
          and it.line_start <= (h.line_end or h.line_start)
        then
          attach(sym.children)
          if not attach_done then
            table.insert(sym.children, it_sym)
            attach_done = true
          end
          return
        end
      end
    end
    -- Simple linear scan: find deepest enclosing in flat list.
    local target = nil
    for _, h in ipairs(hs) do
      if it.line_start >= h.line_start and it.line_start <= (h.line_end or h.line_start) then
        target = h
      end
    end
    if target then
      -- Locate the corresponding sym in the tree by line_start match.
      local function find(syms)
        for _, s in ipairs(syms) do
          if s._h_info and s._h_info.line_start == target.line_start then
            return s
          end
          local r = find(s.children)
          if r then
            return r
          end
        end
      end
      local parent = find(root)
      if parent then
        table.insert(parent.children, it_sym)
      end
    else
      root[#root + 1] = it_sym
    end
  end

  -- Strip the temp `_h_info` fields before returning.
  local function clean(syms)
    for _, s in ipairs(syms) do
      s._h_info = nil
      clean(s.children)
    end
  end
  clean(root)
  return root
end

-- workspace/symbol: cross-file headline search by title fuzzy-match.
handlers["workspace/symbol"] = function(params)
  local query = (params.query or ""):lower()
  local q = require("organ.query")
  local rows = q.headlines({})
  local out = {}
  for _, r in ipairs(rows or {}) do
    local title = r.title or ""
    if query == "" or title:lower():find(query, 1, true) then
      out[#out + 1] = {
        name = title,
        kind = todo_kind(r.todo_state),
        location = {
          uri = path_to_uri(r.file_path),
          range = lsp_range((r.line_start or 0) + 1, 0, (r.line_start or 0) + 1, 0),
        },
        containerName = vim.fn.fnamemodify(r.file_path, ":t"),
      }
    end
  end
  return out
end

-- definition: parse the link under cursor, resolve to its target.
handlers["textDocument/definition"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return nil
  end
  local row = params.position.line
  local col = params.position.character
  local link = require("organ.element").link_at(bufnr, row, col)
  if not link then
    return nil
  end
  local target_part = link.target
  local q = require("organ.query")
  -- id:UUID
  do
    local id = target_part:match("^id:(.+)$")
    if id then
      local rows = q.headlines({ id = id })
      if rows and rows[1] then
        local r = rows[1]
        return {
          uri = path_to_uri(r.file_path),
          range = lsp_range((r.line_start or 0) + 1, 0, (r.line_start or 0) + 1, 0),
        }
      end
      return nil
    end
  end
  -- *Title
  do
    local hl = target_part:match("^%*(.+)$")
    if hl then
      local rows = q.headlines({ title = hl })
      if rows and rows[1] then
        local r = rows[1]
        return {
          uri = path_to_uri(r.file_path),
          range = lsp_range((r.line_start or 0) + 1, 0, (r.line_start or 0) + 1, 0),
        }
      end
      return nil
    end
  end
  -- file:path[::*Anchor]
  do
    local fpath, anchor = target_part:match("^file:([^:]+)::(.+)$")
    if not fpath then
      fpath = target_part:match("^file:(.+)$")
    end
    if fpath then
      local full = vim.fn.fnamemodify(fpath, ":p")
      local target_row = 1
      if anchor then
        local a = anchor:match("^%*(.+)$") or anchor
        local rows = q.headlines({ file_path = full, title = a })
        if rows and rows[1] then
          target_row = (rows[1].line_start or 0) + 1
        end
      end
      return {
        uri = path_to_uri(full),
        range = lsp_range(target_row, 0, target_row, 0),
      }
    end
  end
  return nil
end

-- references: list every `[[id:UUID]]` AND `[[*Title]]` referencing
-- the headline at the cursor.
handlers["textDocument/references"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local row = params.position.line + 1
  local q = require("organ.query")
  -- Find the headline at or above the cursor row.
  local rows = q.headlines({ file_path = path })
  local target = nil
  for _, r in ipairs(rows or {}) do
    if (r.line_start or 0) + 1 <= row then
      target = r
    else
      break
    end
  end
  if not target then
    return {}
  end
  local out = {}
  -- ID-based references.
  if target.id and q.links_to then
    for _, l in ipairs(q.links_to(target.id) or {}) do
      out[#out + 1] = {
        uri = path_to_uri(l.file_path),
        range = lsp_range((l.line or 1), 0, (l.line or 1), 0),
      }
    end
  end
  -- Title-based references via the SQLite index (`query.title_refs`).
  -- Already scanned at index time so the indexer's TS extraction
  -- powers this — no per-call file-text scanning required.
  if target.title and q.title_refs then
    for _, l in ipairs(q.title_refs(target.title) or {}) do
      out[#out + 1] = {
        uri = path_to_uri(l.source_headline and l.source_headline.file_path or l.file_path),
        range = lsp_range((l.line or 1), 0, (l.line or 1), 0),
      }
    end
  end
  return out
end

-- hover: preview the target headline of a link under the cursor.
handlers["textDocument/hover"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return nil
  end
  local row = params.position.line
  local col = params.position.character
  local link = require("organ.element").link_at(bufnr, row, col)
  if not link then
    return nil
  end
  local hover = require("organ.hover")
  local target = hover.resolve(link.target)
  if not target then
    return nil
  end
  local md = table.concat(hover.preview_lines(target), "\n")
  return {
    contents = { kind = "markdown", value = md },
    range = lsp_range(link.line + 1, link.col_start, link.end_line + 1, link.end_col),
  }
end

-- completion: union of all our completion sources.
handlers["textDocument/completion"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return { items = {} }
  end
  local row = params.position.line + 1
  local col = params.position.character
  local items = {}

  local function add(label, insert, kind, detail, filter)
    items[#items + 1] = {
      label = label,
      insertText = insert,
      filterText = filter or label,
      kind = kind,
      detail = detail,
    }
  end

  -- Each source self-detects its trigger context — silent when off.
  local todo = require("organ.complete.todo")
  local p = todo.cursor_partial(bufnr, row, col)
  if p ~= nil then
    for _, it in ipairs(todo.completion_items(p)) do
      add(it.label, it.insertText, KIND.Keyword, "TODO state", it.filterText)
    end
  end

  local tags = require("organ.complete.tags")
  local pt = tags.cursor_partial(bufnr, row, col)
  if pt ~= nil then
    for _, it in ipairs(tags.completion_items(pt)) do
      add(it.label, it.insertText, KIND.EnumMember, it.detail, it.filterText)
    end
  end

  local dir = require("organ.complete.directive")
  local pd = dir.cursor_partial(bufnr, row, col)
  if pd ~= nil then
    for _, it in ipairs(dir.completion_items(pd)) do
      add(
        it.label,
        it.insertText,
        it.kind == "Snippet" and KIND.Constructor or KIND.Keyword,
        it.detail,
        it.filterText
      )
    end
  end

  local src_lang = require("organ.complete.src_lang")
  local psl = src_lang.cursor_partial(bufnr, row, col)
  if psl ~= nil then
    for _, it in ipairs(src_lang.completion_items(psl)) do
      add(it.label, it.insertText, KIND.Module, it.detail, it.filterText)
    end
  end

  -- Drawer source still reads window cursor (it's tied to LSP-driven
  -- contexts where the buffer is current). Acceptable since drawer
  -- completion is interactive-only.
  local drawer = require("organ.complete.drawer")
  local pdr = drawer.cursor_partial(bufnr)
  if pdr ~= "" and pdr ~= nil then
    for _, it in ipairs(drawer.completion_items(pdr)) do
      add(it.label, it.insertText, KIND.Property, nil, it.filterText)
    end
  end

  local complete = require("organ.complete")
  local trig = complete.trigger_at_cursor(bufnr)
  if trig then
    local raw = trig.kind == "property_value" and complete.items_for(trig.kind, trig)
      or complete.items_for(trig.kind, trig.query)
    for _, it in ipairs(raw) do
      add(
        it.display,
        string.format("%s][%s]]", it.insert_text, it.description),
        KIND.Reference,
        nil,
        it.display
      )
    end
  end

  return { isIncomplete = false, items = items }
end

-- rename: change a headline's title and update every link to it.
handlers["textDocument/rename"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local row = params.position.line + 1
  local new_name = params.newName
  if type(new_name) ~= "string" or new_name == "" then
    return nil
  end
  local q = require("organ.query")
  local rows = q.headlines({ file_path = path })
  local target = nil
  for _, r in ipairs(rows or {}) do
    if (r.line_start or 0) + 1 == row then
      target = r
      break
    end
  end
  if not target then
    return nil
  end

  -- Delegate to the refactor module. It already does the title-slot
  -- calculation via element.lua + walks the indexed `[[*OldTitle]]`
  -- references via query.title_refs (no ad-hoc file scan).
  local refactor = require("organ.refactor")
  local edits = refactor.plan(target, new_name)
  if not edits then
    return nil
  end
  local edits_by_uri = {}
  for _, e in ipairs(edits) do
    local uri = path_to_uri(e.path)
    edits_by_uri[uri] = edits_by_uri[uri] or {}
    table.insert(edits_by_uri[uri], {
      range = lsp_range(e.line, e.col_s, e.line, e.col_e),
      newText = e.new_text,
    })
  end
  return { changes = edits_by_uri }
end

-- codeAction: context-aware menu of org actions on the cursor's headline.
handlers["textDocument/codeAction"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local row = params.range.start.line + 1
  local bufnr = vim.fn.bufnr(path)
  local actions = {}
  local function add(title, command, args)
    actions[#actions + 1] = {
      title = title,
      kind = "refactor",
      command = { title = title, command = command, arguments = args or {} },
    }
  end
  local on_headline = false
  if bufnr ~= -1 then
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    on_headline = line:match("^%*+ ") ~= nil
  end
  if on_headline then
    add("Promote subtree", "organ.promote_subtree", { path, row })
    add("Demote subtree", "organ.demote_subtree", { path, row })
    add("Move subtree up", "organ.move_subtree_up", { path, row })
    add("Move subtree down", "organ.move_subtree_down", { path, row })
    add("Cycle TODO state", "organ.todo_cycle", { path, row })
    add("Schedule…", "organ.schedule", { path, row })
    add("Set deadline…", "organ.deadline", { path, row })
    add("Refile…", "organ.refile", { path, row })
    add("Archive subtree", "organ.archive_subtree", { path, row })
    add("Rename headline…", "organ.rename_headline", { path, row })
    add("Set tags…", "organ.set_tags", { path, row })
    add("Set priority…", "organ.set_priority", { path, row })
  else
    add("New headline below", "organ.meta_return", { path, row })
    add("Insert link…", "organ.insert_link", { path, row })
  end
  return actions
end

-- foldingRange: every headline subtree, drawer, lesser-block, list, and
-- inlinetask gets a fold region. TS-driven via element.lua so we cover
-- every grammar-recognised structural node — no regex line scans.
handlers["textDocument/foldingRange"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return {}
  end
  local element = require("organ.element")
  local out = {}
  local function add_range(node)
    local sr, _, er, _ = node:range()
    if er > sr then
      out[#out + 1] = {
        startLine = sr,
        endLine = er - 1,
        kind = "region",
      }
    end
  end
  -- Headlines (subtree folds) via headlines info.
  for _, h in ipairs(element.headlines(bufnr)) do
    if h.line_end and h.line_end > h.line_start then
      out[#out + 1] = {
        startLine = h.line_start,
        endLine = h.line_end,
        kind = "region",
      }
    end
  end
  -- Walk the tree once for the structural nodes we want to fold.
  local FOLDABLE = {
    drawer = true,
    property_drawer = true,
    src_block = true,
    example_block = true,
    export_block = true,
    verse_block = true,
    comment_block = true,
    greater_block = true,
    dynamic_block = true,
    latex_environment = true,
    list = true,
    inlinetask = true,
    footnote_definition = true,
  }
  if element.parser_loaded(bufnr) then
    local root = element.root(bufnr)
    if root then
      local function visit(node)
        if FOLDABLE[node:type()] then
          add_range(node)
        end
        for c in node:iter_children() do
          visit(c)
        end
      end
      visit(root)
    end
  else
    -- Regex fallback: drawer + END pairing only.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local in_drawer = nil
    for i, ln in ipairs(lines) do
      local name = ln:match("^%s*:([%w_]+):%s*$")
      if name and name ~= "END" and not in_drawer then
        in_drawer = { start = i }
      elseif ln:match("^%s*:END:%s*$") and in_drawer then
        out[#out + 1] = { startLine = in_drawer.start - 1, endLine = i - 1, kind = "region" }
        in_drawer = nil
      end
    end
  end
  return out
end

-- documentLink: every `[[...]]` in the doc. TS-driven via element.links.
handlers["textDocument/documentLink"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return {}
  end
  local out = {}
  for _, l in ipairs(require("organ.element").links(bufnr)) do
    out[#out + 1] = {
      range = lsp_range(l.line + 1, l.col_start, l.end_line + 1, l.end_col),
      tooltip = l.target,
      target = nil, -- resolved on textDocument/documentLink/resolve
      data = { body = l.target, file = path },
    }
  end
  return out
end

-- formatting: rewrap prose paragraphs (preserves headlines, lists,
-- drawers, blocks, tables).  Returns one full-buffer TextEdit so
-- the client (Neovim's vim.lsp.buf.format → conform.nvim → ...)
-- replaces the document atomically.
local function format_handler(bufnr, lo_0, hi_0)
  local total = vim.api.nvim_buf_line_count(bufnr)
  lo_0 = lo_0 or 0
  hi_0 = hi_0 or total
  if hi_0 > total then
    hi_0 = total
  end
  if lo_0 < 0 then
    lo_0 = 0
  end
  if hi_0 <= lo_0 then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo_0, hi_0, false)
  local out = require("organ.format").format_lines(lines, nil, bufnr)
  return {
    {
      range = {
        start = { line = lo_0, character = 0 },
        ["end"] = { line = hi_0, character = 0 },
      },
      newText = table.concat(out, "\n") .. (#out > 0 and "\n" or ""),
    },
  }
end

handlers["textDocument/formatting"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return {}
  end
  return format_handler(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

handlers["textDocument/rangeFormatting"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return {}
  end
  local r = params.range
  -- LSP range end is exclusive at the column level; round to the
  -- start of the line after when end.character > 0.
  local hi = r["end"].line + (r["end"].character > 0 and 1 or 0)
  return format_handler(bufnr, r.start.line, hi)
end

-- diagnostic: broken links (id: → unknown ID, *Title → unknown headline).
handlers["textDocument/diagnostic"] = function(params)
  local path = uri_to_path(params.textDocument.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return { kind = "full", items = {} }
  end
  local q = require("organ.query")
  local items = {}
  for _, l in ipairs(require("organ.element").links(bufnr)) do
    local id = l.target:match("^id:(.+)$")
    local title = l.target:match("^%*(.+)$")
    local broken_msg = nil
    if id then
      local rows = q.headlines({ id = id })
      if not (rows and rows[1]) then
        broken_msg = "Unknown ID: " .. id
      end
    elseif title then
      local rows = q.headlines({ title = title })
      if not (rows and rows[1]) then
        broken_msg = "No headline matches *" .. title
      end
    end
    if broken_msg then
      items[#items + 1] = {
        range = lsp_range(l.line + 1, l.col_start, l.end_line + 1, l.end_col),
        severity = 2, -- Warning
        source = "organ",
        message = broken_msg,
      }
    end
  end
  return { kind = "full", items = items }
end

-- ── server boilerplate ────────────────────────────────────────────────

local function make_server()
  local closing = false
  local srv = {}
  function srv.request(method, params, callback)
    if method == "initialize" then
      callback(nil, {
        capabilities = {
          positionEncoding = "utf-8",
          textDocumentSync = { openClose = true, change = 1 }, -- 1 = full
          documentSymbolProvider = true,
          workspaceSymbolProvider = true,
          definitionProvider = true,
          referencesProvider = true,
          hoverProvider = true,
          completionProvider = {
            triggerCharacters = { ":", "*", "[", "+", "#" },
            resolveProvider = false,
          },
          renameProvider = true,
          codeActionProvider = true,
          foldingRangeProvider = true,
          documentLinkProvider = { resolveProvider = false },
          documentFormattingProvider = true,
          documentRangeFormattingProvider = true,
          diagnosticProvider = {
            interFileDependencies = true,
            workspaceDiagnostics = false,
          },
        },
        serverInfo = { name = SERVER_NAME, version = "0.1.0" },
      })
      return
    end
    if method == "shutdown" then
      callback(nil, nil)
      return
    end
    local h = handlers[method]
    if h then
      require("organ.errors").schedule("organ.lsp", function()
        local ok, res = pcall(h, params)
        if ok then
          callback(nil, res)
        else
          callback({ code = -32603, message = tostring(res) }, nil)
        end
      end)
      return
    end
    callback(nil, nil)
  end
  function srv.notify(method, _params)
    if method == "exit" then
      closing = true
    end
    -- didOpen / didChange / didClose: no-op (we read buffers live).
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    closing = true
  end
  return srv
end

-- Resolve the workspace root for a buffer: prefer the configured org_dir
-- if the file is under it; fall back to the file's parent directory.
local function root_for(path)
  local org_dir = require("organ.buf_config").read(nil, "org_dir")
  if org_dir and org_dir ~= "" then
    org_dir = vim.fn.fnamemodify(org_dir, ":p"):gsub("/+$", "")
    local full = vim.fn.fnamemodify(path, ":p")
    if full:sub(1, #org_dir) == org_dir then
      return org_dir
    end
  end
  return vim.fn.fnamemodify(path, ":h")
end

-- Public: attach the server to `bufnr` (defaults to current buffer).
-- Idempotent — re-attaching to a buffer is a no-op.
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  local root = root_for(path)
  local existing = clients_by_root[root]
  if existing then
    vim.lsp.buf_attach_client(bufnr, existing)
    return existing
  end
  local client_id = vim.lsp.start({
    name = SERVER_NAME,
    cmd = function(_dispatchers)
      return make_server()
    end,
    root_dir = root,
    filetypes = { "org" },
  }, { bufnr = bufnr })
  if client_id then
    clients_by_root[root] = client_id
  end
  return client_id
end

-- Internal: handlers table (exposed for tests).
M._handlers = handlers

return M
