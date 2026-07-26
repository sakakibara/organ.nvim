-- PDF export smoke test.
--
-- Covers two engines:
--   * "lua" (default): pure-Lua renderer, requires a system TTF but no
--     LaTeX toolchain.  Skipped when no font is discoverable.
--   * "pdflatex" / "xelatex" / "lualatex": shell-out path.  When none
--     of those engines is on PATH we still run the missing-engine
--     failure check.
--
-- The PDF format is a binary; we don't parse it, just verify the
-- bytes carry the `%PDF-` magic and `%%EOF` trailer.
--
-- Run via: nvim --headless -l tests/export_pdf_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function which_latex_engine()
  for _, e in ipairs({ "pdflatex", "xelatex", "lualatex" }) do
    if vim.fn.executable(e) == 1 then
      return e
    end
  end
  return nil
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local function fresh_buffer()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* Heading 1",
    "Some prose.",
    "",
    "** Subheading",
    "More prose.",
  })
  vim.bo[b].filetype = "org"
  return b
end

local pdf = require("organ.export.pdf")
local font_search = require("organ.pdf.font_search")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function pdf_bytes_look_valid(path)
  local f = io.open(path, "rb")
  if not f then
    return false, "could not open " .. path
  end
  local head = f:read(8) or ""
  -- Read the trailing 8 bytes to confirm %%EOF (writers may add a
  -- trailing newline, hence the rstrip in the assertion below).
  f:seek("end", -8)
  local tail = f:read(8) or ""
  f:close()
  if head:sub(1, 5) ~= "%PDF-" then
    return false, ("head=%q"):format(head)
  end
  -- Trim trailing whitespace; the EOF marker may sit before \n.
  local trimmed = tail:gsub("%s+$", "")
  if not trimmed:find("%%%%EOF$") then
    return false, ("tail=%q"):format(tail)
  end
  return true
end

-- Lua engine (default).

local ttf, ferr = font_search.find({ style = "regular" })
if ttf then
  print(("(using font: %s)"):format(ttf))

  -- 1. Default engine is "lua".
  do
    local b = fresh_buffer()
    local out = vim.fn.tempname() .. ".pdf"
    local path, err = pdf.export_buffer_to_file(b, out, {})
    check(
      "default engine writes a PDF",
      path == out,
      ("path=%s err=%s"):format(tostring(path), tostring(err))
    )
    if path and vim.fn.filereadable(path) == 1 then
      local ok, detail = pdf_bytes_look_valid(path)
      check("default-engine PDF has %PDF- magic and %%EOF trailer", ok, detail)
      local size = vim.loop.fs_stat(path).size
      check("default-engine PDF size > 0", size > 0, ("size=%d"):format(size))
      pcall(vim.fn.delete, path)
    end
  end

  -- 2. Explicit engine = "lua".
  do
    local b = fresh_buffer()
    local out = vim.fn.tempname() .. ".pdf"
    local path, err = pdf.export_buffer_to_file(b, out, { engine = "lua" })
    check(
      "explicit engine='lua' writes a PDF",
      path == out,
      ("path=%s err=%s"):format(tostring(path), tostring(err))
    )
    if path and vim.fn.filereadable(path) == 1 then
      local ok, detail = pdf_bytes_look_valid(path)
      check("engine='lua' PDF has %PDF- magic and %%EOF trailer", ok, detail)
      pcall(vim.fn.delete, path)
    end
  end

  -- 3. export_buffer returns bytes directly under the lua engine.
  do
    local b = fresh_buffer()
    local bytes, err = pdf.export_buffer(b, { engine = "lua" })
    check(
      "export_buffer returns PDF bytes",
      type(bytes) == "string" and bytes:sub(1, 5) == "%PDF-",
      ("err=%s head=%q"):format(tostring(err), bytes and bytes:sub(1, 8) or "")
    )
  end

  -- 4. Bad explicit font path surfaces a clear engine-tagged error.
  do
    local b = fresh_buffer()
    local out = vim.fn.tempname() .. ".pdf"
    local path, err = pdf.export_buffer_to_file(b, out, {
      engine = "lua",
      font_path = "/definitely/not/a/real/font.ttf",
    })
    check(
      "missing font yields a clear lua-engine error",
      path == nil and type(err) == "string" and err:find("export.pdf (lua engine)", 1, true) ~= nil,
      ("path=%s err=%s"):format(tostring(path), tostring(err))
    )
  end
else
  print("SKIP  lua engine checks: no system TTF found (" .. tostring(ferr) .. ")")
end

-- LaTeX engine path.

local latex_engine = which_latex_engine()
if latex_engine then
  local b = fresh_buffer()
  local out = vim.fn.tempname() .. ".pdf"
  local path, err = pdf.export_buffer_to_file(b, out, { engine = latex_engine })
  check(
    ("engine=%s writes a PDF"):format(latex_engine),
    path == out,
    ("path=%s err=%s"):format(tostring(path), tostring(err))
  )
  if path and vim.fn.filereadable(path) == 1 then
    local ok, detail = pdf_bytes_look_valid(path)
    check(("engine=%s PDF has %%PDF- magic and %%%%EOF trailer"):format(latex_engine), ok, detail)
    pcall(vim.fn.delete, path)
  end
else
  print("SKIP  latex-engine happy path: no pdflatex/xelatex/lualatex on PATH")
end

-- Missing-engine error message must come from the LaTeX path, not the
-- lua path: pick an obviously bogus engine name so we route into
-- via_latex_engine and hit the executable check.
do
  local b = fresh_buffer()
  local _, missing_err = pdf.export_buffer_to_file(
    b,
    vim.fn.tempname() .. ".pdf",
    { engine = "definitely_not_a_real_engine" }
  )
  check(
    "missing LaTeX engine yields a clear error",
    type(missing_err) == "string" and missing_err:find("not in PATH", 1, true) ~= nil,
    ("err=%s"):format(tostring(missing_err))
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("export_pdf_test: PASS")
os.exit(0)
