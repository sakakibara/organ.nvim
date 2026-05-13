-- Roam graph view for organ.nvim.
--
-- Exposes:
--   M.adjacency(node_id, depth)  -> list of edges { from, to, kind }
--   M.tree(node_id, depth)       -> { lines, line_index } for floating popup
--   M.mermaid(node_id, depth)    -> string (flowchart LR diagram)
--   M.show(node_id, depth)       -> open the tree popup

local M = {}

local obuf = require("organ.buf")
local function file_short(path)
  if not path then
    return ""
  end
  return vim.fn.fnamemodify(path, ":t")
end

-- Build the (forward + backward) adjacency rooted at `node_id` to depth N.
-- Returns: nodes (id → {title, file_path, line_start}), edges {{from, to, kind}}.
function M.adjacency(node_id, depth)
  depth = math.max(1, depth or 1)
  local query = require("organ.query")
  local nodes, edges = {}, {}
  local seen_node, seen_edge = {}, {}

  local function add_node(id, file_path, title, line_start)
    if not id or seen_node[id] then
      return
    end
    seen_node[id] = true
    nodes[id] = {
      id = id,
      title = title or "(untitled)",
      file_path = file_path,
      line_start = line_start,
    }
  end

  local function add_edge(from, to, kind)
    if not from or not to then
      return
    end
    local key = from .. ">" .. to .. "|" .. kind
    if seen_edge[key] then
      return
    end
    seen_edge[key] = true
    edges[#edges + 1] = { from = from, to = to, kind = kind }
  end

  local root = query.get_by_id(node_id)
  if not root then
    return nodes, edges
  end
  add_node(root.id, root.file_path, root.title, root.line_start)

  local frontier = { root.id }
  for d = 1, depth do
    local next_frontier = {}
    for _, id in ipairs(frontier) do
      -- Forward: links from this node.
      local forward = query.links_from(id) or {}
      for _, l in ipairs(forward) do
        local h = l.target_headline
        if h and h.id then
          add_node(h.id, h.file_path, h.title, h.line_start)
          add_edge(id, h.id, "forward")
          next_frontier[#next_frontier + 1] = h.id
        end
      end
      -- Backward: links to this node.
      local backward = query.links_to(id) or {}
      for _, l in ipairs(backward) do
        local h = l.source_headline
        if h and h.id then
          add_node(h.id, h.file_path, h.title, h.line_start)
          add_edge(h.id, id, "forward")
          next_frontier[#next_frontier + 1] = h.id
        end
      end
    end
    if d < depth then
      frontier = next_frontier
    end
  end

  return nodes, edges
end

local function indent(n)
  return string.rep("  ", n)
end

-- Build a tree-style view rooted at node_id, showing up to `depth` levels of
-- forward + backward links.  Returns lines and a line_index from line number
-- to { id = ..., file_path = ..., line_start = ... } for jumps.
function M.tree(node_id, depth)
  depth = math.max(1, depth or 1)
  local query = require("organ.query")
  local lines, line_index = {}, {}

  local function emit(text, jump)
    lines[#lines + 1] = text
    if jump then
      line_index[#lines] = jump
    end
  end

  local function emit_node(id, prefix, level, kind)
    local h = query.get_by_id(id)
    if not h then
      emit(prefix .. "? " .. id, nil)
      return
    end
    local arrow = kind == "forward" and "→ " or kind == "backward" and "← " or ""
    emit(
      prefix
        .. arrow
        .. (h.title or "(untitled)")
        .. "  ::  "
        .. file_short(h.file_path)
        .. ":"
        .. tostring((h.line_start or 0) + 1),
      { id = id, file_path = h.file_path, line_start = h.line_start }
    )
    if level >= depth then
      return
    end
    local forward = query.links_from(id) or {}
    for _, l in ipairs(forward) do
      local th = l.target_headline
      if th and th.id and th.id ~= id then
        emit_node(th.id, indent(level + 1) .. "→ ", level + 1, nil)
      end
    end
    local backward = query.links_to(id) or {}
    for _, l in ipairs(backward) do
      local sh = l.source_headline
      if sh and sh.id and sh.id ~= id then
        emit_node(sh.id, indent(level + 1) .. "← ", level + 1, nil)
      end
    end
  end

  emit_node(node_id, "", 0, nil)
  return lines, line_index
end

-- Render the adjacency as a Mermaid flowchart-LR document.
function M.mermaid(node_id, depth)
  local nodes, edges = M.adjacency(node_id, depth)
  local out = { "flowchart LR" }
  -- Node declarations with shortened ids (replace dashes / digits with underscores).
  local function safe(id)
    return (id or ""):gsub("[^%w_]", "_")
  end
  for id, n in pairs(nodes) do
    local label = (n.title or "(untitled)"):gsub('"', "'")
    out[#out + 1] = string.format('    %s["%s"]', safe(id), label)
  end
  for _, e in ipairs(edges) do
    out[#out + 1] = string.format("    %s --> %s", safe(e.from), safe(e.to))
  end
  return table.concat(out, "\n")
end

-- Open a floating window with the tree view; <CR> jumps; q closes.
function M.show(node_id, depth)
  if not node_id or node_id == "" then
    require("organ.notify").warn("organ.roam.graph: no node id at cursor")
    return
  end
  local lines, line_index = M.tree(node_id, depth or 1)
  local buf = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(buf, 0, -1, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(120, vim.o.columns - 4),
    height = math.min(#lines + 2, vim.o.lines - 4),
    row = 2,
    col = 2,
    border = "rounded",
    title = " Roam graph ",
  })
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end,
  })
  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
    noremap = true,
    silent = true,
    callback = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local jump = line_index[lnum]
      if not jump or not jump.file_path then
        return
      end
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.cmd("edit " .. vim.fn.fnameescape(jump.file_path))
      if jump.line_start then
        vim.api.nvim_win_set_cursor(0, { jump.line_start + 1, 0 })
      end
    end,
  })
end

return M
