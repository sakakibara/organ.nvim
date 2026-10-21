-- organ side of the babel-links conformance gate: writes each case into a
-- fresh directory, runs its operations through organ's babel, link,
-- footnote and citation modules, and prints the result in the shape
-- emacs.el prints (see NORMALIZE.md).

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

pcall(function()
  require("organ").setup({
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })
end)

local buf_config = require("organ.buf_config")

local POINT_OPS = { follow = true, ["fn-action"] = true, ["fn-new"] = true }
local QUIET_OPS = { follow = true, ["cite-parse"] = true, ["bib-files"] = true }

-- Option runs: name -> function(bufnr) applying the option.
local OPTIONS = {
  ["id-link-nil"] = function(bufnr)
    buf_config.set(bufnr, "links.id_link_policy", false)
  end,
}

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function parse(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  local header, files = {}, {}
  local i = 1
  while lines[i] do
    local key, value = lines[i]:match("^#%+CONFORMANCE%-([%u%-]+): (.*)$")
    if not key or key == "FILE" then
      break
    end
    header[#header + 1] = { key, value }
    i = i + 1
  end
  local name, body = "case.org", {}
  for j = i, #lines do
    local fname = lines[j]:match("^#%+CONFORMANCE%-FILE: (.+)$")
    if fname then
      files[#files + 1] = { name, table.concat(body, "\n") .. "\n" }
      name, body = fname, {}
    else
      body[#body + 1] = lines[j]
    end
  end
  files[#files + 1] = { name, table.concat(body, "\n") .. "\n" }
  return header, files
end

local function values(header, key)
  local out = {}
  for _, h in ipairs(header) do
    if h[1] == key then
      out[#out + 1] = h[2]
    end
  end
  return out
end

local function words(s)
  local out = {}
  for w in s:gmatch("%S+") do
    out[#out + 1] = w
  end
  return out
end

local function snapshot(dir)
  local out = {}
  for name, kind in vim.fs.dir(dir, { depth = math.huge }) do
    local full = dir .. "/" .. name
    if kind == "link" then
      out[name] = "link\0" .. (vim.uv.fs_readlink(full) or "")
    elseif kind == "file" then
      local st = vim.uv.fs_stat(full)
      out[name] = string.format("file\0%o\0%s", st.mode % 512, read(full))
    end
  end
  return out
end

local function file_lines(before, after)
  local names = {}
  for name in pairs(after) do
    names[#names + 1] = name
  end
  for name in pairs(before) do
    if not after[name] then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local a = after[name]
    if not a then
      out[#out + 1] = "--- " .. name .. " (deleted)"
    elseif a ~= before[name] then
      local kind, rest = a:match("^(%a+)%z(.*)$")
      if kind == "link" then
        out[#out + 1] = "--- " .. name .. " -> " .. rest
      else
        local mode, text = rest:match("^(%d+)%z(.*)$")
        out[#out + 1] = "--- " .. name .. " (" .. mode .. ")"
        vim.list_extend(out, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
      end
    end
  end
  return out
end

local function where(dir)
  local name = vim.api.nvim_buf_get_name(0)
  for _, d in ipairs({ dir, vim.fn.resolve(dir) }) do
    if name:sub(1, #d + 1) == d .. "/" then
      name = name:sub(#d + 2)
    end
  end
  local c = vim.api.nvim_win_get_cursor(0)
  return string.format("%s %d:%d", name, c[1], c[2])
end

local function quote(s)
  if s == nil then
    return "nil"
  end
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function cite_dump(bufnr)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local out = {}
  for _, hit in ipairs(require("organ.cite").scan(text)) do
    local p = hit.parsed
    local _, nl = text:sub(1, hit.s):gsub("\n", "")
    local style = p.style == "default" and not p.variant and "nil"
      or (p.style .. (p.variant and ("/" .. p.variant) or ""))
    local refs = {}
    for _, r in ipairs(p.refs) do
      refs[#refs + 1] = string.format("(%s %s %s)", r.key, quote(r.prefix), quote(r.suffix))
    end
    out[#out + 1] = string.format(
      "L%d style=%s pre=%s suf=%s refs=%s",
      nl + 1,
      style,
      quote(p.prefix),
      quote(p.suffix),
      table.concat(refs, " ")
    )
  end
  return out
end

local function store(bufnr, file, dir)
  local link = require("organ.link")
  local link_store = require("organ.link_store")
  if file then
    vim.cmd("silent edit " .. vim.fn.fnameescape(dir .. "/" .. file))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    link.store_link()
    vim.cmd("silent buffer " .. bufnr)
  else
    link.store_link()
  end
  local e = link_store.list()[1]
  local stored = "nil"
  if e then
    if e.kind == "id" then
      stored = "id:" .. e.id
    elseif e.kind == "file_headline" then
      stored = "file:" .. e.file_path .. "::*" .. e.headline
    elseif e.kind == "file_line" then
      stored = "file:" .. e.file_path .. "::" .. e.line
    else
      stored = e.url
    end
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, n, n, false, { "" })
  vim.api.nvim_win_set_cursor(0, { n + 1, 0 })
  link.insert_link()
  return { "=== stored " .. stored, "=== description " .. ((e and e.title) or "nil") }
end

-- Runs one operation; returns output lines, or false when organ reports
-- that it did nothing (the analogue of an Emacs user-error).
local function run_op(spec, bufnr, dir)
  local w = words(spec)
  local op = w[1]
  local babel = require("organ.babel")
  local footnote = require("organ.footnote")
  local cite = require("organ.cite")
  if op == "execute" then
    return babel.execute(bufnr) ~= false and {}
  elseif op == "execute-buffer" then
    local _, errors = babel.execute_buffer(bufnr)
    return #errors == 0 and {}
  elseif op == "tangle" then
    babel.tangle(bufnr)
    return {}
  elseif op == "follow" then
    require("organ.link").follow()
    return {}
  elseif op == "store" then
    return store(bufnr, w[2], dir)
  elseif op == "insert-link" then
    local desc = #w > 2 and table.concat(w, " ", 3) or nil
    require("organ.link_store").push({ kind = "url", url = w[2], title = desc })
    require("organ.link").insert_link()
    return {}
  elseif op == "fn-action" then
    return footnote.jump(bufnr) ~= false and {}
  elseif op == "fn-new" then
    footnote.insert()
    return {}
  elseif op == "fn-sort" then
    footnote.sort()
    return {}
  elseif op == "fn-normalize" then
    footnote.normalize_inline(bufnr)
    return {}
  elseif op == "fn-renumber" then
    footnote.renumber()
    return {}
  elseif op == "fn-delete" then
    error("organ has no footnote delete")
  elseif op == "cite-parse" then
    return vim.list_extend({ "=== citations" }, cite_dump(bufnr))
  elseif op == "cite-insert" then
    local find = require("organ.find")
    local pick = find.pick
    find.pick = function(opts)
      for _, item in ipairs(opts.items) do
        if item._key == w[2] then
          opts.actions[opts.default_action](item)
        end
      end
    end
    local ok, err = pcall(cite.commands["cite find"].fn)
    find.pick = pick
    assert(ok, err)
    return {}
  elseif op == "cite-bibliography" then
    cite.commands["cite bibliography"].fn({ args = "" })
    return {}
  elseif op == "bib-files" then
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local out = vim.list_extend({ "=== bibliography" }, cite.find_bibliographies(text))
    out[#out + 1] = "=== keys"
    for _, it in ipairs(cite.completion_items("", { bufnr = bufnr })) do
      out[#out + 1] = it.key
    end
    return out
  end
  return { unknown = op }
end

local function replace_dirs(text, base, dir)
  for _, pair in ipairs({
    { vim.fn.resolve(dir), "<DIR>" },
    { dir, "<DIR>" },
    { vim.fn.resolve(base), "<ROOT>" },
    { base, "<ROOT>" },
  }) do
    text = text:gsub(vim.pesc(pair[1]), pair[2])
  end
  return text
end

-- Answer prompts yes, record them and every URL handed to the browser,
-- pick the first item of a selection and silence notifications for one
-- case; returns the function restoring the originals.  Replacing them is
-- the point, hence the ignored warning.
local function stub_ui(prompts, opens)
  local saved = { vim.fn.confirm, vim.ui.open, vim.ui.select, vim.notify }
  -- luacheck: push ignore 122
  vim.fn.confirm = function(msg)
    prompts[#prompts + 1] = msg
    return 1
  end
  vim.ui.open = function(url)
    opens[#opens + 1] = url
  end
  vim.ui.select = function(items, _, cb)
    cb(items[1], 1)
  end
  vim.notify = function() end
  return function()
    vim.fn.confirm, vim.ui.open, vim.ui.select, vim.notify = unpack(saved)
  end
  -- luacheck: pop
end

local M = {}

function M.render(path, option)
  local header, files = parse(read(path))
  local options = words(values(header, "OPTIONS")[1] or "")
  if option and not vim.tbl_contains(options, option) then
    return "(not in the " .. option .. " run)\n"
  end
  local base = vim.fn.tempname()
  local dir = base .. "/w"
  vim.fn.mkdir(dir, "p")
  for _, f in ipairs(files) do
    write(dir .. "/" .. f[1], f[2])
  end
  for _, d in ipairs(values(header, "DIR")) do
    vim.fn.mkdir(dir .. "/" .. d, "p")
  end
  for _, s in ipairs(values(header, "SYMLINK")) do
    local w = words(s)
    assert(vim.uv.fs_symlink(w[2], dir .. "/" .. w[1]))
  end
  local before = snapshot(base)
  local ops = values(header, "OP")
  local first_op = words(ops[1])[1]
  local prompts, opens = {}, {}
  local restore = stub_ui(prompts, opens)
  local cwd = vim.fn.getcwd()
  local out = {}
  local ok, err = pcall(function()
    vim.fn.chdir(base)
    require("organ.link_store").clear()
    vim.cmd("silent edit " .. vim.fn.fnameescape(dir .. "/case.org"))
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "org" then
      vim.bo[bufnr].filetype = "org"
    end
    local cursor = { 1, 0 }
    for _, marker in ipairs({ "<MARK>", "<CURSOR>" }) do
      for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        local s = l:find(marker, 1, true)
        if s then
          vim.api.nvim_buf_set_lines(
            bufnr,
            i - 1,
            i,
            false,
            { l:sub(1, s - 1) .. l:sub(s + #marker) }
          )
          cursor = { i, s - 1 }
          break
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, cursor)
    vim.bo[bufnr].modified = false
    if option then
      OPTIONS[option](bufnr)
    end
    local env = setmetatable({
      B = bufnr,
      DIR = dir,
      M = function(m)
        return require("organ." .. m)
      end,
      set = function(p, v)
        buf_config.set(bufnr, p, v)
      end,
    }, { __index = _G })
    for _, stmt in ipairs(values(header, "ORGAN")) do
      local chunk = assert(loadstring(stmt))
      setfenv(chunk, env)
      chunk()
    end
    for _, spec in ipairs(ops) do
      local okop, lines = pcall(run_op, spec, bufnr, dir)
      if okop and lines and lines.unknown then
        error("conformance: unknown op " .. tostring(lines.unknown))
      elseif okop and lines then
        vim.list_extend(out, lines)
      elseif okop then
        out[#out + 1] = "! error " .. spec
      else
        out[#out + 1] = "! crash: "
          .. tostring(lines)
            :gsub("%S*%.lua:%d+: ", "")
            :gsub('%[string "[^"]*"%]:%d+: ', "")
            :gsub("\n", " ")
      end
    end
    if POINT_OPS[first_op] then
      out[#out + 1] = "=== point " .. where(dir)
    end
    if first_op == "follow" then
      out[#out + 1] = "=== line " .. vim.api.nvim_get_current_line()
    end
    if not QUIET_OPS[first_op] then
      out[#out + 1] = "=== buffer"
      vim.list_extend(out, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end
  end)
  restore()
  vim.fn.chdir(cwd)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:find(base, 1, true) or name:find(vim.fn.resolve(base), 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if not ok then
    vim.fn.delete(base, "rf")
    error(err)
  end
  for _, u in ipairs(opens) do
    out[#out + 1] = "=== open " .. u
  end
  if #values(header, "PROMPTS") > 0 then
    out[#out + 1] = "=== prompts"
    for _, p in ipairs(prompts) do
      out[#out + 1] = "? " .. p:gsub("\n", "\\n")
    end
  end
  local changed = file_lines(before, snapshot(base))
  if #changed > 0 then
    out[#out + 1] = "=== files"
    vim.list_extend(out, changed)
  end
  vim.fn.delete(base, "rf")
  return replace_dirs(table.concat(out, "\n") .. "\n", base, dir)
end

return M
