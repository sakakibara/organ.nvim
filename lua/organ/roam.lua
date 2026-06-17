-- Roam node create-on-no-match for organ.nvim.

local M = {}

local slugify = require("organ.slug").slugify

function M.create_node(title)
  if type(title) ~= "string" or title:match("^%s*$") then
    require("organ.notify").warn("organ.roam: cannot create a node from an empty title")
    return
  end
  title = title:gsub("^%s+", ""):gsub("%s+$", "")
  local cfg = require("organ.buf_config").read(nil, "roam") or {}
  local dir = cfg.dir or vim.fn.expand("~/org/roam")
  vim.fn.mkdir(dir, "p")
  local slug = slugify(title)

  local fname
  if type(cfg.file_template) == "function" then
    local ok, result = pcall(cfg.file_template, title)
    if not ok then
      require("organ.notify").error(
        "organ.roam: file_template errored, falling back to default: " .. tostring(result)
      )
    else
      fname = result
    end
  end

  -- Open the existing note rather than writing a timestamped twin.
  local existing
  if fname then
    if vim.loop.fs_stat(dir .. "/" .. fname) then
      existing = dir .. "/" .. fname
    end
  else
    for _, p in ipairs(vim.fn.glob(dir .. "/*-" .. slug .. ".org", false, true)) do
      existing = p
      break
    end
  end

  if existing then
    require("organ.notify").info("organ: file exists, opening: " .. existing)
    vim.cmd("edit " .. vim.fn.fnameescape(existing))
    return
  end

  -- Default scheme `<YYYYMMDDHHMMSS>-<slug>.org` matches Emacs org-roam.
  if not fname then
    fname = os.date("%Y%m%d%H%M%S") .. "-" .. slug .. ".org"
  end
  local full = dir .. "/" .. fname

  local note = require("organ.roam.note")
  local id = require("organ.id").generate()
  local default_body = note.header(id, title)
  local body
  if type(cfg.body_template) == "function" then
    local ok, result = pcall(cfg.body_template, title, id)
    if not ok then
      require("organ.notify").error(
        "organ.roam: body_template errored, falling back to default: " .. tostring(result)
      )
      body = default_body
    else
      body = result
    end
  else
    body = default_body
  end

  local ok, werr = require("organ.path").write_atomic(full, table.concat(body, "\n") .. "\n")
  if not ok then
    require("organ.notify").error("organ: failed to write " .. full .. ": " .. tostring(werr))
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(full))
  -- Land at the end of the last header line (the title for the default
  -- node, mirroring where org-roam leaves point after the capture head).
  local last = #body
  vim.api.nvim_win_set_cursor(0, { last, #(body[last] or "") })
end

local function capture_ctx()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cword = vim.fn.expand("<cword>")
  local in_link, in_comment = false, false
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if ok and parser then
    parser:parse()
    local node = vim.treesitter.get_node({ bufnr = bufnr, lang = "org" })
    while node do
      if node:type() == "link" then
        in_link = true
        break
      end
      node = node:parent()
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  if line:match("^%s*#") then
    in_comment = true
  end
  return {
    bufnr = bufnr,
    cursor = cursor,
    cword = cword,
    in_link = in_link,
    in_comment = in_comment,
  }
end

local function id_at_cursor(bufnr)
  bufnr = bufnr or 0
  local line = vim.fn.line(".")
  local property = require("organ.property")
  local ok, entries = pcall(property.list, bufnr, line)
  if ok and entries then
    for _, e in ipairs(entries) do
      if e.key == "ID" then
        return e.value
      end
    end
  end
  -- Fall back to the file-level :ID: in the leading property drawer
  -- (zeroth section), since org-roam files often store the node ID
  -- there rather than on a headline.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 80, false)
  local in_drawer = false
  for _, l in ipairs(lines) do
    local trimmed = l:match("^%s*(.-)%s*$")
    if trimmed == ":PROPERTIES:" then
      in_drawer = true
    elseif trimmed == ":END:" then
      in_drawer = false
    elseif in_drawer then
      local v = trimmed:match("^:ID:%s*(%S+)")
      if v then
        return v
      end
    elseif trimmed:match("^%*") then
      break
    end
  end
  return nil
end

M.commands = {
  roam = {
    fn = function()
      require("organ.find").pick({
        source = "headlines",
        filter = { has_id = true },
        title = "Roam node",
        default_action = "jump",
        create = function(query)
          M.create_node(query)
        end,
      })
    end,
    desc = "Find roam node (or create on no match)",
  },
  ["roam insert"] = {
    fn = function()
      local find = require("organ.find")
      find.pick({
        source = "headlines",
        filter = { has_id = true },
        title = "Insert roam link",
        default_action = "insert_link",
        actions = { insert_link = find.make_insert_link_action(capture_ctx()) },
      })
    end,
    desc = "Insert id link to roam node at cursor",
  },
  ["roam daily today"] = {
    fn = function()
      require("organ.roam.dailies").today()
    end,
    desc = "Open today's daily note",
  },
  ["roam daily yesterday"] = {
    fn = function()
      require("organ.roam.dailies").yesterday()
    end,
    desc = "Open yesterday's daily note",
  },
  ["roam daily tomorrow"] = {
    fn = function()
      require("organ.roam.dailies").tomorrow()
    end,
    desc = "Open tomorrow's daily note",
  },
  ["roam daily"] = {
    fn = function(cmd)
      if cmd and cmd.args and cmd.args ~= "" then
        require("organ.roam.dailies").for_date(cmd.args)
      else
        require("organ.roam.dailies").pick_date()
      end
    end,
    nargs = "?",
    desc = "Open a daily note (no arg: calendar; arg: ISO date)",
  },
  ["roam graph"] = {
    fn = function(cmd)
      local depth = tonumber(cmd and cmd.args) or 1
      local id = id_at_cursor(0)
      if not id then
        require("organ.notify").warn("no roam node id at cursor or in file header")
        return
      end
      require("organ.roam.graph").show(id, depth)
    end,
    nargs = "?",
    desc = "Show the roam graph (forward + back-links) of the node at cursor",
  },
  ["roam graph_mermaid"] = {
    fn = function(cmd)
      local depth = tonumber(cmd and cmd.args) or 1
      local id = id_at_cursor(0)
      if not id then
        require("organ.notify").warn("no roam node id at cursor")
        return
      end
      local doc = require("organ.roam.graph").mermaid(id, depth)
      vim.fn.setreg("+", doc)
      require("organ.notify").info(
        "mermaid diagram copied to clipboard ("
          .. #vim.split(doc, "\n", { plain = true })
          .. " lines)"
      )
    end,
    nargs = "?",
    desc = "Copy a Mermaid flowchart of the roam graph to the clipboard",
  },
  ["roam buffer"] = {
    fn = function()
      require("organ.roam.sidebar").toggle()
    end,
    desc = "Toggle the persistent right-side roam backlinks sidebar",
  },
  ["roam linkify"] = {
    fn = function(cmd)
      local lk = require("organ.roam.linkify")
      local bufnr = vim.api.nvim_get_current_buf()
      local n
      if cmd and cmd.range and cmd.range > 0 then
        n = lk.linkify_range(bufnr, cmd.line1, cmd.line2)
      else
        n = lk.linkify_cword(bufnr)
      end
      require("organ.notify").notify(
        n > 0 and vim.log.levels.INFO or vim.log.levels.WARN,
        ("linkified %d match(es)"):format(n)
      )
    end,
    range = true,
    desc = "Linkify word at cursor (or selected range) to a roam node by title/alias",
  },
  ["roam linkify_buffer"] = {
    fn = function()
      local n = require("organ.roam.linkify").linkify_buffer(0)
      require("organ.notify").info(("linkified %d match(es) across buffer"):format(n))
    end,
    desc = "Linkify every line in the current buffer (best-effort)",
  },
}

return M
