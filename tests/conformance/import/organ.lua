-- Import gate, organ side: each example's Markdown goes through
-- `:Org import markdown <file>` exactly as a user runs it, and the org
-- buffer it opens is exported to HTML by Emacs (emacs.el,
-- conformance-import-export), one Emacs process per case.  Output per
-- example: a `=== <label> ===` line, then the HTML, or one
-- ORGAN-ERROR / EMACS-ERROR line.

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

local dir = root .. "/tests/conformance/import"
local FENCE = string.rep("`", 32)

local M = {}

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

--- Examples of a case file: list of { label, markdown, html }.
function M.examples(path)
  local out, label, state, md, html = {}, nil, nil, {}, {}
  for _, line in ipairs(vim.split(read(path), "\n", { plain = true })) do
    if state == "md" then
      if line == "." then
        state = "html"
      else
        md[#md + 1] = line
      end
    elseif state == "html" then
      if line == FENCE then
        out[#out + 1] = {
          label = label,
          markdown = table.concat(md, "\n") .. "\n",
          html = #html > 0 and (table.concat(html, "\n") .. "\n") or "",
        }
        state, md, html = nil, {}, {}
      else
        html[#html + 1] = line
      end
    elseif line:sub(1, 3) == "## " then
      label = line:sub(4)
    elseif line == FENCE .. " example" then
      state = "md"
    end
  end
  return out
end

-- Strip the "<file>:<line>: " prefix so the message does not move with
-- unrelated edits or checkout paths.
local function error_line(prefix, msg)
  msg = tostring(msg):gsub("^[^\n]-:%d+: ", ""):gsub("%s+", " ")
  return prefix .. vim.trim(msg) .. "\n"
end

-- The import opens its result with :enew, which reuses an empty unnamed
-- current buffer; starting from a named, non-empty one makes the result
-- always a new buffer.
local holder

local function import(md_path)
  if not (holder and vim.api.nvim_buf_is_valid(holder)) then
    holder = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(holder, 0, -1, false, { "holder" })
    vim.api.nvim_buf_set_name(holder, vim.fn.tempname() .. "-holder")
    vim.bo[holder].modified = false
  end
  vim.api.nvim_set_current_buf(holder)
  local before = holder
  local ok, err = pcall(
    require("organ.import").commands["import markdown"].fn,
    { fargs = { md_path }, args = md_path, bang = false }
  )
  local buf = vim.api.nvim_get_current_buf()
  local text
  if ok and buf ~= before then
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  end
  if buf ~= before then
    vim.cmd("silent! bwipeout! " .. buf)
  end
  if not ok then
    return nil, err
  end
  if not text then
    return nil, "import opened no buffer"
  end
  return text
end

function M.render(path, _option)
  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  local examples = M.examples(path)
  local names, results = {}, {}
  for i, ex in ipairs(examples) do
    local name = string.format("%04d", i)
    write(work .. "/" .. name .. ".md", ex.markdown)
    local org, err = import(work .. "/" .. name .. ".md")
    if org then
      write(work .. "/" .. name .. ".org", org)
      names[#names + 1] = name
    else
      results[i] = error_line("ORGAN-ERROR: ", err)
    end
  end
  write(work .. "/list", table.concat(names, "\n") .. "\n")
  local log = vim.fn.system({
    "timeout",
    "-k",
    "5",
    "300",
    "emacs",
    "--batch",
    "-Q",
    "-l",
    dir .. "/emacs.el",
    "--eval",
    string.format("(conformance-import-export %q)", work),
  })
  if vim.v.shell_error ~= 0 then
    error(string.format("emacs export failed (exit %d): %s", vim.v.shell_error, log:sub(1, 2000)))
  end
  local parts = {}
  for i, ex in ipairs(examples) do
    local name = string.format("%04d", i)
    local body = results[i]
    if not body then
      local html = work .. "/" .. name .. ".html"
      if vim.fn.filereadable(html) == 1 then
        body = read(html)
      else
        body = error_line("EMACS-ERROR: ", read(work .. "/" .. name .. ".err"))
      end
    end
    if body ~= "" and body:sub(-1) ~= "\n" then
      body = body .. "\n"
    end
    parts[#parts + 1] = "=== " .. ex.label .. " ===\n" .. body
  end
  vim.fn.delete(work, "rf")
  return table.concat(parts)
end

return M
