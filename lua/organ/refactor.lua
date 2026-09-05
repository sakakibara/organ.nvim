-- Headline rename refactoring.
--
-- Renames the headline at the cursor and updates every `[[*OldTitle]]`
-- reference across all indexed files. ID-based links are unaffected
-- (they survive renames by design — that's the point of having an ID).
--
-- Writes use organ.path.write_atomic so a crash mid-rename can't leave
-- a half-written file.

local M = {}

-- Build the edit list:
--   { { path, line_idx (1-based), col_start, col_end, new_text }, ... }
-- Returns a flat list across all affected files. Caller may preview
-- before applying.
function M.plan(target_row, new_name)
  if type(new_name) ~= "string" or new_name == "" then
    return nil, "new name must be non-empty"
  end
  local q = require("organ.query")
  if not target_row or not target_row.file_path then
    return nil, "no headline at cursor"
  end
  local edits = {}

  -- 1. The headline line itself. Use TS to find the exact title-node
  -- range so we replace ONLY the title text (preserving stars / TODO /
  -- priority / tags). Falls back to regex when the parser isn't loaded
  -- (e.g. the file isn't open as a buffer).
  do
    local fp = target_row.file_path
    local idx = (target_row.line_start or 0) + 1
    local bufnr = vim.fn.bufnr(fp)
    if bufnr == -1 then
      bufnr = vim.fn.bufadd(fp)
      vim.fn.bufload(bufnr)
    elseif not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    local element = require("organ.element")
    local h = element.headline_at(bufnr, idx - 1)
    local title_range = nil
    if h and h.node then
      for c in h.node:iter_children() do
        if c:type() == "headline_line" then
          local title_node = (c:field("title") or {})[1]
          if title_node then
            local sr, sc, _, ec = title_node:range()
            title_range = { line = sr + 1, col_s = sc, col_e = ec }
          end
          break
        end
      end
    end
    if title_range then
      -- Trim trailing whitespace from title text before replacing.
      local line = vim.api.nvim_buf_get_lines(bufnr, idx - 1, idx, false)[1] or ""
      local title_text = line:sub(title_range.col_s + 1, title_range.col_e)
      local trimmed = title_text:gsub("%s+$", "")
      edits[#edits + 1] = {
        path = fp,
        line = idx,
        col_s = title_range.col_s,
        col_e = title_range.col_s + #trimmed,
        new_text = new_name,
      }
    else
      -- Fallback for buffers without a parser.
      local lines = vim.fn.readfile(fp)
      local line = lines[idx] or ""
      local stars, rest = line:match("^(%*+) +(.*)$")
      if stars and rest then
        local seq = require("organ.buf_config").read(nil, "todo.sequence") or {}
        local cursor = #stars + 1
        for _, kw in ipairs(seq) do
          if kw ~= "|" and rest:sub(1, #kw + 1) == kw .. " " then
            cursor = cursor + #kw + 1
            rest = rest:sub(#kw + 2)
            break
          end
        end
        local pri = rest:match("^(%[#[A-Z0-9]%])%s+")
        if pri then
          cursor = cursor + #pri + 1
          rest = rest:sub(#pri + 2)
        end
        local title_part = rest:gsub("%s+:[%w_@#%%:%-]+:%s*$", "")
        edits[#edits + 1] = {
          path = fp,
          line = idx,
          col_s = cursor,
          col_e = cursor + #title_part,
          new_text = new_name,
        }
      end
    end
  end

  -- 2. `[[*OldTitle]]` references across all indexed files. We use
  -- TS via element.links on each file (loaded into a scratch buffer
  -- if not already open), so the link extraction is grammar-driven
  -- and inert blocks (src/example/etc.) are correctly excluded.
  local old_title = target_row.title
  if old_title and old_title ~= "" then
    local element = require("organ.element")
    local seen_files = {}
    local function scan(fp)
      if not fp or seen_files[fp] then
        return
      end
      if not vim.uv.fs_stat(fp) then
        return
      end
      seen_files[fp] = true
      local bufnr = vim.fn.bufnr(fp)
      if bufnr == -1 then
        bufnr = vim.fn.bufadd(fp)
        vim.fn.bufload(bufnr)
      elseif not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
      end
      for _, l in ipairs(element.links(bufnr)) do
        local hl = l.target:match("^%*(.+)$")
        if hl == old_title then
          local new_body = "*"
            .. new_name
            .. (l.description ~= "" and ("][" .. l.description) or "")
          edits[#edits + 1] = {
            path = fp,
            line = l.line + 1,
            col_s = l.col_start,
            col_e = l.end_col,
            new_text = "[[" .. new_body .. "]]",
          }
        end
      end
    end
    -- Prefer the SQLite index's title_refs when available — narrows
    -- the file set substantially. Otherwise iterate q.files().
    if q.title_refs then
      for _, ref in ipairs(q.title_refs(old_title) or {}) do
        scan(ref.source_headline and ref.source_headline.file_path or ref.file_path)
      end
    end
    -- Catch-all: also scan every listed file. Idempotent via seen_files.
    for _, f in ipairs((q.files and q.files()) or {}) do
      scan(f.file_path or f.path or f)
    end
  end

  return edits
end

-- Apply the plan: group edits by file, splice each file's lines, and
-- write atomically. Returns (n_files_changed, n_edits) or (nil, err).
function M.apply(edits)
  if not edits or #edits == 0 then
    return 0, 0
  end
  local by_file = {}
  for _, e in ipairs(edits) do
    by_file[e.path] = by_file[e.path] or {}
    table.insert(by_file[e.path], e)
  end
  local n_files = 0
  for path, file_edits in pairs(by_file) do
    -- Sort descending by (line, col_s) so earlier edits don't shift
    -- later ones' column positions.
    table.sort(file_edits, function(a, b)
      if a.line ~= b.line then
        return a.line > b.line
      end
      return a.col_s > b.col_s
    end)
    local lines = vim.fn.readfile(path)
    for _, e in ipairs(file_edits) do
      local ln = lines[e.line] or ""
      lines[e.line] = ln:sub(1, e.col_s) .. e.new_text .. ln:sub(e.col_e + 1)
    end
    local ok, werr = require("organ.path").write_atomic(path, table.concat(lines, "\n") .. "\n")
    if not ok then
      return nil, werr
    end
    -- Reload buffer if open.
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("checktime")
      end)
    end
    n_files = n_files + 1
  end
  return n_files, #edits
end

-- Public: end-to-end rename. Resolve the headline at cursor, prompt
-- (or take new_name), confirm, apply.
function M.rename_at_cursor(new_name)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local path = vim.api.nvim_buf_get_name(bufnr)
  local q = require("organ.query")
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
    require("organ.notify").warn("no headline at cursor")
    return
  end
  local proceed = function(name)
    if not name or name == "" then
      return
    end
    local edits, err = M.plan(target, name)
    if not edits then
      require("organ.notify").warn("rename: " .. tostring(err))
      return
    end
    -- Count files for confirmation.
    local files = {}
    for _, e in ipairs(edits) do
      files[e.path] = true
    end
    local n = 0
    for _ in pairs(files) do
      n = n + 1
    end
    local prompt = string.format(
      "Rename %q → %q in %d file%s (%d edit%s)? [y/N] ",
      target.title or "?",
      name,
      n,
      n == 1 and "" or "s",
      #edits,
      #edits == 1 and "" or "s"
    )
    vim.ui.input({ prompt = prompt }, function(answer)
      if not answer or not answer:match("^[Yy]") then
        require("organ.notify").info("rename cancelled")
        return
      end
      local nf, ne = M.apply(edits)
      if not nf then
        require("organ.notify").warn("rename failed: " .. tostring(ne))
      else
        require("organ.notify").info(
          string.format(
            "renamed in %d file%s (%d edit%s)",
            nf,
            nf == 1 and "" or "s",
            ne,
            ne == 1 and "" or "s"
          )
        )
      end
    end)
  end
  if new_name then
    proceed(new_name)
  else
    vim.ui.input({ prompt = "New title: ", default = target.title }, function(name)
      proceed(name)
    end)
  end
end

return M
