-- Link action dispatcher for organ.nvim.
--
-- M.resolve(target_text) -> (target_type, stripped_target)
--   Classifies an org link target by prefix.
--
-- M.open is implemented in a later task once query.get_by_id exists.

local M = {}

local obuf = require("organ.buf")
local STRIP_PREFIXES = { "id:", "file:", "attachment:" }

-- Schemes that pass through verbatim as URLs (no `:` stripping for the action).
local URL_SCHEMES = {
  http = true,
  https = true,
  mailto = true,
  news = true,
  gopher = true,
  ftp = true,
  ftps = true,
  tel = true,
}

-- Schemes that map to a synthetic URL via a known template (Emacs parity).
local SYNTH_URL = {
  doi = function(rest)
    return "https://doi.org/" .. rest
  end,
}

-- Schemes that need OS-specific dispatch (handled in M.open).
local SPECIAL_SCHEMES = { info = true, man = true, help = true, elisp = true, shell = true }

-- Scan the buffer for `#+LINK: name template` directives. Returns a table
-- { name = template_with_optional_%s }. Pure parse; no side effects.
function M.parse_abbrev(bufnr)
  local out = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return out
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, ln in ipairs(lines) do
    -- Stop scanning when we hit the first headline; #+KEYWORDS only count
    -- before the first heading per org spec.
    if ln:match("^%*+%s") then
      break
    end
    local name, template = ln:match("^%s*#%+LINK:%s+(%S+)%s+(.+)%s*$")
    if name and template then
      out[name] = template
    end
  end
  return out
end

-- Apply an abbrev template. "%s" → tag verbatim; "%h" → URL-encoded.
local function apply_abbrev(template, tag)
  -- find(... , true) is plain search — pass literal `%h` / `%s`.
  if template:find("%h", 1, true) then
    -- gsub uses Lua pattern syntax: `%%` matches a literal `%`.
    -- Wrap `tag` so any `%` inside gets escaped against the replacement
    -- shorthand (`%0`, `%1`, …).
    return (template:gsub("%%h", (vim.uri_encode(tag)):gsub("%%", "%%%%")))
  end
  if template:find("%s", 1, true) then
    local escaped = (tag or ""):gsub("%%", "%%%%")
    return (template:gsub("%%s", escaped))
  end
  return template .. tag
end

function M.resolve(target_text, opts)
  if type(target_text) ~= "string" or target_text == "" then
    return "text", target_text or ""
  end

  if target_text:sub(1, 5) == "file:" then
    local rest = target_text:sub(6)
    local file_part, anchor = rest:match("^(.-)::(.+)$")
    if file_part then
      return "file", file_part, anchor
    end
    return "file", rest, nil
  end

  for _, p in ipairs(STRIP_PREFIXES) do
    if target_text:sub(1, #p) == p then
      local scheme = p:sub(1, -2)
      return scheme, target_text:sub(#p + 1)
    end
  end

  local scheme, rest = target_text:match("^([a-zA-Z][a-zA-Z0-9+._-]*):(.*)$")
  if scheme then
    -- Abbreviated link expansion (#+LINK: name template).
    local abbrev = (opts and opts.abbrev) or {}
    if abbrev[scheme] then
      local expanded = apply_abbrev(abbrev[scheme], rest)
      return M.resolve(expanded, opts)
    end
    if URL_SCHEMES[scheme] then
      return scheme, target_text
    end
    if SYNTH_URL[scheme] then
      return "url_synth", SYNTH_URL[scheme](rest)
    end
    if SPECIAL_SCHEMES[scheme] then
      return scheme, rest
    end
    return scheme, rest
  end

  if target_text:sub(1, 1) == "*" then
    return "headline", target_text:sub(2)
  end

  if
    target_text:sub(1, 1) == "/"
    or target_text:sub(1, 2) == "./"
    or target_text:sub(1, 3) == "../"
  then
    return "file", target_text
  end

  return "text", target_text
end

local function expand_file_path(path, source_file_path)
  path = vim.fn.expand(path) -- handles ~ and $VAR
  if path:sub(1, 1) == "/" then
    return path
  end -- already absolute
  if source_file_path and source_file_path ~= "" then
    local dir = vim.fn.fnamemodify(source_file_path, ":h")
    return dir .. "/" .. path
  end
  return vim.fn.fnamemodify(path, ":p") -- cwd-relative fallback
end

-- Turn a target text into an action record. Callers handle UI side-effects.
--
-- `opts.abbrev` (table) is consulted for #+LINK: abbreviations; pass
-- M.parse_abbrev(bufnr) when you want buffer-local abbrevs to apply.
-- `opts.bufnr` / `opts.line` locate the headline whose attachment
-- directory resolves `attachment:` links (default: cursor position).
function M.open(target_text, source_file_path, opts)
  local ttype, target, anchor = M.resolve(target_text, opts)

  if ttype == "attachment" then
    local bufnr = (opts and opts.bufnr) or vim.api.nvim_get_current_buf()
    local line = (opts and opts.line) or vim.api.nvim_win_get_cursor(0)[1]
    local file, att_anchor = target:match("^(.-)::(.+)$")
    local dir, err = require("organ.attach").dir(bufnr, line, { create = false })
    if not dir then
      return { kind = "error", reason = "attachment: " .. err }
    end
    return { kind = "edit_file", path = dir .. "/" .. (file or target), anchor = att_anchor }
  end

  if ttype == "id" then
    local query = require("organ.query")
    local rec = query.get_by_id(target)
    if rec then
      return { kind = "jump_headline", file_path = rec.file_path, line = rec.line_start + 1 }
    end
    return { kind = "error", reason = "id not indexed: " .. target }
  end

  if ttype == "file" then
    return {
      kind = "edit_file",
      path = expand_file_path(target, source_file_path),
      anchor = anchor,
    }
  end

  if URL_SCHEMES[ttype] then
    return { kind = "url", url = target }
  end

  if ttype == "url_synth" then
    return { kind = "url", url = target }
  end

  if ttype == "headline" then
    return { kind = "headline_search", title_match = target }
  end

  if ttype == "info" then
    -- vim.cmd("Man") covers `man:`; for `info:` we shell out to the system
    -- info reader (no in-Neovim equivalent ships by default).
    return { kind = "info", node = target }
  end

  if ttype == "man" then
    return { kind = "man", page = target }
  end

  if ttype == "help" then
    return { kind = "help", topic = target }
  end

  if ttype == "elisp" or ttype == "shell" then
    -- Security: never auto-execute. Caller must opt in explicitly via the
    -- `links.allow_unsafe` config flag (checked at dispatch time).
    return { kind = "unsafe", scheme = ttype, command = target }
  end

  if ttype and ttype ~= "text" then
    return { kind = "property_value", key = ttype, value = target }
  end

  return { kind = "error", reason = "unsupported target: " .. tostring(target_text) }
end

-- Dispatch the side-effect kinds that aren't already handled elsewhere.
function M.dispatch_man(action)
  pcall(vim.cmd, "Man " .. vim.fn.fnameescape(action.page))
end

function M.dispatch_help(action)
  pcall(vim.cmd, "help " .. vim.fn.fnameescape(action.topic))
end

function M.dispatch_info(action)
  -- Best-effort: shell out to `info` if present; otherwise notify.
  if vim.fn.executable("info") == 1 then
    vim.fn.jobstart({ "info", action.node }, { detach = true })
    return
  end
  require("organ.notify").warn("`info` command not on PATH (node: " .. action.node .. ")")
end

function M.dispatch_unsafe(action)
  local cfg = (require("organ.buf_config").read(nil, "links") or {})
  if not cfg.allow_unsafe then
    require("organ.notify").warn(
      ("refusing to run %s: link (set config.links.allow_unsafe=true to enable)"):format(
        action.scheme
      )
    )
    return
  end
  if action.scheme == "shell" then
    -- Confirm even when allow_unsafe is on; gate with vim.fn.confirm.
    local ans = vim.fn.confirm("Run shell command:\n" .. action.command, "&Run\n&Cancel", 2)
    if ans ~= 1 then
      return
    end
    vim.fn.jobstart(action.command, { detach = true })
    return
  end
  if action.scheme == "elisp" then
    require("organ.notify").warn("elisp: links cannot be evaluated outside Emacs")
  end
end

-- Search-string form used by `org-link-search`: statistics cookies
-- dropped, whitespace collapsed, case folded.
local function normalize_search_string(s)
  s = s:gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " ")
  s = s:gsub("[ \t]+", " "):match("^%s*(.-)%s*$")
  return s:upper()
end

-- Headline text without TODO keyword, priority, COMMENT and tags
-- (`(org-get-heading t t t t)`), or nil when `line` is not a headline.
local function headline_search_text(line, todo_keywords)
  local level, rest = require("organ.headline").split(line)
  if not level then
    return nil
  end
  rest = rest:gsub("[ \t]+:[%w_@#%%:\128-\255]+:[ \t]*$", "")
  local first, after = rest:match("^(%S+)%s*(.*)$")
  if first and todo_keywords[first] then
    rest = after
  end
  rest = rest:gsub("^%[#[%u%d]%][ \t]*", "")
  rest = rest:gsub("^COMMENT[ \t]+", "")
  return rest
end

function M.dispatch_edit_file(action)
  vim.cmd("edit " .. vim.fn.fnameescape(action.path))
  if not action.anchor then
    return
  end

  local a = action.anchor
  local lookup
  if a:sub(1, 1) == "*" then
    lookup = { kind = "headline", value = a:sub(2) }
  elseif a:sub(1, 1) == "#" then
    lookup = { kind = "custom_id", value = a:sub(2) }
  elseif a:match("^/.+/$") then
    lookup = { kind = "regex", value = a:sub(2, -2) }
  elseif a:match("^%d+$") then
    lookup = { kind = "line", value = tonumber(a) }
  else
    lookup = { kind = "text", value = a }
  end

  -- DB fast path for headline / custom_id.
  local row = nil
  if lookup.kind == "headline" or lookup.kind == "custom_id" then
    local query = require("organ.query")
    if lookup.kind == "headline" then
      local wanted = normalize_search_string(lookup.value)
      local rows = query.headlines({ file = action.path, title_match = lookup.value })
      for _, r in ipairs(rows) do
        if normalize_search_string(r.title) == wanted then
          row = r
          break
        end
      end
    else
      local rows = query.headlines({
        file = action.path,
        has_property = "CUSTOM_ID",
        include_properties = true,
      })
      for _, r in ipairs(rows) do
        local props = r.properties or {}
        if props["CUSTOM_ID"] == lookup.value then
          row = r
          break
        end
      end
    end
  end

  if row then
    pcall(vim.api.nvim_win_set_cursor, 0, { row.line_start + 1, 0 })
    return
  end

  -- File-buffer scan fallback.
  if lookup.kind == "line" then
    pcall(vim.api.nvim_win_set_cursor, 0, { lookup.value, 0 })
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local wanted, todo_keywords
  if lookup.kind == "headline" then
    wanted = normalize_search_string(lookup.value)
    todo_keywords = {}
    local todo = require("organ.todo")
    for _, k in ipairs(todo.all_keywords(todo.effective_sequences(0))) do
      todo_keywords[k] = true
    end
  end
  for i, line in ipairs(lines) do
    local hit = false
    if lookup.kind == "headline" then
      local text = headline_search_text(line, todo_keywords)
      hit = text ~= nil and normalize_search_string(text) == wanted
    elseif lookup.kind == "custom_id" then
      hit = line:match("^%s*:CUSTOM_ID:%s+" .. vim.pesc(lookup.value) .. "%s*$") ~= nil
    elseif lookup.kind == "regex" then
      local ok, m = pcall(string.match, line, lookup.value)
      hit = ok and m ~= nil
    elseif lookup.kind == "text" then
      hit = line:find(lookup.value, 1, true) ~= nil
    end
    if hit then
      pcall(vim.api.nvim_win_set_cursor, 0, { i, 0 })
      return
    end
  end

  require("organ.notify").warn("organ: anchor not found: " .. action.anchor)
end

function M.dispatch_property_value(action)
  local query = require("organ.query")
  local rows = query.headlines({
    has_property = action.key,
    include_properties = true,
  })

  -- Token-membership match: split each property value on whitespace and
  -- compare each token exactly to action.value. Handles multi-value
  -- ROAM_REFS naturally; single-value props degrade fine.
  local matches = {}
  for _, r in ipairs(rows) do
    local raw = (r.properties or {})[action.key]
    if raw then
      for tok in raw:gmatch("%S+") do
        if tok == action.value then
          matches[#matches + 1] = r
          break
        end
      end
    end
  end

  if #matches == 0 then
    require("organ.notify").warn(
      string.format("no headline with %s = %s", action.key, action.value)
    )
    return
  end

  if #matches == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(matches[1].file_path))
    pcall(vim.api.nvim_win_set_cursor, 0, { matches[1].line_start + 1, 0 })
    return
  end

  -- >=2 matches: hand off to the snacks picker (or _test_stub in tests),
  -- pre-filtered. find.pick honors opts.items for source="headlines".
  local find = require("organ.find")
  find.pick({
    source = "headlines",
    items = matches,
    default_action = "jump",
    prompt = string.format("%s = %s: ", action.key, action.value),
  })
end

-- Apply an `{ kind = ..., ... }` action returned by `M.open(...)`.  The
-- action shapes are the canonical link-resolution result; this dispatches
-- each kind to the right side-effect (open file, jump headline, follow
-- URL, etc.).
function M.dispatch(action)
  if action.kind == "edit_file" then
    M.dispatch_edit_file(action)
  elseif action.kind == "jump_headline" then
    vim.cmd("edit " .. vim.fn.fnameescape(action.file_path))
    vim.api.nvim_win_set_cursor(0, { action.line, 0 })
  elseif action.kind == "url" then
    if vim.ui.open then
      vim.ui.open(action.url)
    else
      require("organ.notify").info("organ: url " .. action.url)
    end
  elseif action.kind == "headline_search" then
    require("organ.notify").warn("organ: headline search not wired: " .. action.title_match)
  elseif action.kind == "property_value" then
    M.dispatch_property_value(action)
  elseif action.kind == "man" then
    M.dispatch_man(action)
  elseif action.kind == "help" then
    M.dispatch_help(action)
  elseif action.kind == "info" then
    M.dispatch_info(action)
  elseif action.kind == "unsafe" then
    M.dispatch_unsafe(action)
  elseif action.kind == "error" then
    require("organ.notify").error(action.reason)
  end
end

-- Schemes recognized in plain (bare) and angle links.  Emacs limits
-- `org-link-plain-re` to registered link types the same way, so prose
-- like `note: this` never becomes a link.
local PLAIN_SCHEMES = (function()
  local s = { id = true, file = true, attachment = true }
  for _, tbl in ipairs({ URL_SCHEMES, SYNTH_URL, SPECIAL_SCHEMES }) do
    for k in pairs(tbl) do
      s[k] = true
    end
  end
  return s
end)()

-- Find the org plain link (`scheme:path` outside brackets) or angle
-- link (`<scheme:path>`, which may contain spaces) covering 1-based
-- `col` in `line_text`.  Returns { target, start, ["end"] } or nil.
function M.plain_link_at(line_text, col)
  -- Angle links first: explicit boundaries win over the bare matcher.
  local pos = 1
  while true do
    local s, e, target = line_text:find("<(%a[%w+.-]*:[^<>]+)>", pos)
    if not s then
      break
    end
    local scheme = target:match("^(%a[%w+.-]*):")
    if PLAIN_SCHEMES[scheme] and col >= s and col <= e then
      return { target = target, start = s, ["end"] = e }
    end
    pos = e + 1
  end
  pos = 1
  while true do
    local s, e, scheme, path = line_text:find("(%a[%w+.-]*):([^%s%[%]<>]+)", pos)
    if not s then
      break
    end
    local prev = s > 1 and line_text:sub(s - 1, s - 1) or ""
    if not prev:match("%w") and PLAIN_SCHEMES[scheme] then
      -- org-link-plain-re: the path ends with a non-punctuation char,
      -- a `/`, or a `)` closing a paren opened inside the path.
      local target = scheme .. ":" .. path
      while #target > 0 do
        local last = target:sub(-1)
        if last == "/" then
          break
        elseif last == ")" then
          local _, opens = target:gsub("%(", "")
          local _, closes = target:gsub("%)", "")
          if closes > opens then
            target = target:sub(1, -2)
          else
            break
          end
        elseif last:match("%p") then
          target = target:sub(1, -2)
        else
          break
        end
      end
      local te = s + #target - 1
      if #target > #scheme + 1 and col >= s and col <= te then
        return { target = target, start = s, ["end"] = te }
      end
      pos = e + 1
    else
      -- Rejected match may still contain a valid link further in
      -- (`x-http://…` hides `http://…`); rescan from the next char.
      pos = s + 1
    end
  end
  return nil
end

-- High-level action: follow the link under (`opts.bufnr`, `opts.line`,
-- `opts.col`).  All keys default to current buffer + cursor.  Walks the
-- line for `[[…]]`/`[[…][…]]` spans plus plain/angle links, picks the
-- one covering the column, resolves it via `M.open`, and dispatches the
-- resulting action.
function M.follow(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = opts.line or cursor[1]
  local col = opts.col or (cursor[2] + 1)
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local links, pos2 = {}, 1
  while true do
    local s, e, target, desc = line_text:find("%[%[([^%]]+)%]%[(.-.)%]%]", pos2)
    local s2, e2, target2 = line_text:find("%[%[([^%]]+)%]%]", pos2)
    local pick_full = s and (not s2 or s <= s2)
    if pick_full then
      links[#links + 1] = { target = target, description = desc, start = s, ["end"] = e }
      pos2 = e + 1
    elseif s2 then
      links[#links + 1] = { target = target2, description = nil, start = s2, ["end"] = e2 }
      pos2 = e2 + 1
    else
      break
    end
  end
  local target_text
  for _, lk in ipairs(links) do
    if col >= lk.start and col <= lk["end"] then
      target_text = lk.target
      break
    end
  end
  if not target_text then
    local plain = M.plain_link_at(line_text, col)
    if plain then
      target_text = plain.target
    end
  end
  if not target_text then
    local def = require("organ.radio").def_at(bufnr, line, col)
    if def then
      vim.api.nvim_win_set_cursor(0, { def.line, def.col })
      pcall(vim.cmd, "normal! zv")
      return
    end
    require("organ.notify").warn("no link at cursor")
    return
  end
  local source = vim.api.nvim_buf_get_name(bufnr)
  local action =
    M.open(target_text, source, { abbrev = M.parse_abbrev(bufnr), bufnr = bufnr, line = line })
  M.dispatch(action)
end

-- Store a link to the current location into the session link kill-ring.
-- On a headline: stores either an :ID: link (per id_link_policy) or a
-- file::*Headline link.  Off a headline: stores a file:line entry.
function M.store_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local store = require("organ.link_store")
  local structure = require("organ.structure")
  local notify_msg = function(msg)
    if require("organ.buf_config").read(nil, "notify") then
      require("organ.errors").schedule("organ.link", function()
        require("organ.notify").info(msg)
      end)
    end
  end

  local hl = structure._find_containing_headline(bufnr, line)
  if hl then
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    -- id_link_policy: "create" always inserts an :ID:; "use-existing"
    -- uses one if present, else file::*Headline (default — no surprise
    -- drawer writes); "create-if-interactive" is "create" here since
    -- :Org store_link is always interactive; false / nil → never :ID:.
    local cfg_links = (require("organ.buf_config").read(nil, "links") or {})
    local policy = cfg_links.id_link_policy
    if policy == nil then
      policy = "use-existing"
    end
    local entry
    if policy == "create" or policy == "create-if-interactive" then
      local id = require("organ.id").get_or_create(bufnr, hl.line)
      if not id then
        return
      end
      entry = { kind = "id", id = id, title = hl.title_text, file_path = file_path }
    elseif policy == "use-existing" then
      local id = require("organ.id").get(bufnr, hl.line)
      if id then
        entry = { kind = "id", id = id, title = hl.title_text, file_path = file_path }
      else
        entry = {
          kind = "file_headline",
          file_path = file_path,
          title = hl.title_text,
          headline = hl.title_text,
        }
      end
    else
      entry = {
        kind = "file_headline",
        file_path = file_path,
        title = hl.title_text,
        headline = hl.title_text,
      }
    end
    store.push(entry)
    notify_msg("stored: " .. hl.title_text)
  else
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    if file_path == "" then
      file_path = "[No Name]"
    end
    local basename = vim.fn.fnamemodify(file_path, ":t")
    local title = basename .. ":" .. line
    local entry = { kind = "file_line", file_path = file_path, line = line, title = title }
    store.push(entry)
    notify_msg("stored: " .. title)
  end
end

-- Pick a stored link via vim.ui.select and insert it at cursor.
function M.insert_link()
  local store = require("organ.link_store")
  local entries = store.list()
  if #entries == 0 then
    if require("organ.buf_config").read(nil, "notify") then
      require("organ.errors").schedule("organ.link", function()
        require("organ.notify").info("no stored links")
      end)
    end
    return
  end

  local labels = {}
  for _, e in ipairs(entries) do
    labels[#labels + 1] = e.title or e.url
  end

  vim.ui.select(labels, { prompt = "Insert link: " }, function(choice, idx)
    if not choice or not entries[idx] then
      return
    end
    local e = entries[idx]
    local link_text
    if e.kind == "id" then
      link_text = "[[id:" .. e.id .. "][" .. e.title .. "]]"
    elseif e.kind == "url" then
      if e.title and e.title ~= "" then
        link_text = "[[" .. e.url .. "][" .. e.title .. "]]"
      else
        link_text = "[[" .. e.url .. "]]"
      end
    elseif e.kind == "file_headline" then
      link_text = "[[file:" .. e.file_path .. "::*" .. e.headline .. "][" .. e.title .. "]]"
    else
      local basename = vim.fn.fnamemodify(e.file_path, ":t")
      link_text = "[[file:"
        .. e.file_path
        .. "::"
        .. e.line
        .. "]["
        .. basename
        .. ":"
        .. e.line
        .. "]]"
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local cur = vim.api.nvim_win_get_cursor(0)
    local crow, ccol = cur[1], cur[2]
    local line_text = vim.api.nvim_buf_get_lines(bufnr, crow - 1, crow, false)[1] or ""
    local new_text = line_text:sub(1, ccol) .. link_text .. line_text:sub(ccol + 1)
    obuf.set_lines(bufnr, crow - 1, crow, { new_text })
  end)
end

M.commands = {
  follow_link = {
    fn = function()
      M.follow()
    end,
    desc = "Follow the org link under the cursor",
  },
  store_link = {
    fn = function()
      M.store_link()
    end,
    desc = "Store link to current headline (or file:line) in the session link kill-ring",
  },
  insert_link = {
    fn = function()
      M.insert_link()
    end,
    desc = "Insert a link from the session link kill-ring at cursor",
  },
}

return M
