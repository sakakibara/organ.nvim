-- PDF export smoke test: render a small org buffer to .pdf via the
-- configured LaTeX engine.  Skips when no engine is available -- the
-- test environment isn't required to ship pdflatex / xelatex /
-- lualatex; CI installs at most one of them.
--
-- The PDF format is a binary; we don't parse it, just verify that the
-- engine produced a non-empty file with the `%PDF-` magic.
--
-- Run via: nvim --headless -l tests/export_pdf_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function which_engine()
  for _, e in ipairs({ "pdflatex", "xelatex", "lualatex" }) do
    if vim.fn.executable(e) == 1 then
      return e
    end
  end
  return nil
end

local engine = which_engine()
if not engine then
  print("(skipped: no LaTeX engine in PATH)")
  print("export_pdf_test: SKIP")
  os.exit(0)
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

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

local out = vim.fn.tempname() .. ".pdf"
local pdf = require("organ.export.pdf")
local path, err = pdf.export_buffer_to_file(b, out, { engine = engine })

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

check(
  "export_buffer_to_file returned the path",
  path == out,
  ("path=%s err=%s"):format(tostring(path), tostring(err))
)
check("PDF file exists", path and vim.fn.filereadable(path) == 1)

if path and vim.fn.filereadable(path) == 1 then
  local f = io.open(path, "rb")
  local head = f and f:read(8) or ""
  if f then
    f:close()
  end
  check("file starts with PDF magic (%PDF-)", head:sub(1, 5) == "%PDF-", ("got %q"):format(head))
  local size = vim.loop.fs_stat(path).size
  check("PDF size > 0", size > 0, ("size=%d"):format(size))
  pcall(vim.fn.delete, path)
end

-- Failure path: missing engine.
local _, missing_err = pdf.export_buffer_to_file(
  b,
  vim.fn.tempname() .. ".pdf",
  { engine = "definitely_not_a_real_engine" }
)
check(
  "missing engine yields a clear error",
  type(missing_err) == "string" and missing_err:find("not in PATH", 1, true) ~= nil,
  ("err=%s"):format(tostring(missing_err))
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print(("export_pdf_test: PASS (engine=%s)"):format(engine))
os.exit(0)
