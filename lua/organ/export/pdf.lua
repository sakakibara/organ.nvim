-- PDF exporter for org buffers.
--
-- Two-step: render the buffer to LaTeX via `organ.export.latex`, then
-- compile that to PDF by spawning the user's chosen LaTeX engine
-- (pdflatex by default; xelatex / lualatex selectable via opts.engine
-- or fold.export.pdf.engine in setup config).  The .tex source and
-- engine logs are kept in a temp directory; only the .pdf is moved to
-- the user-visible target path.
--
-- Default engine: pdflatex.  Pass opts.engine = "xelatex" to compile
-- with xelatex instead (Unicode + system fonts).  Same arg works for
-- lualatex.

local M = {}

local function default_engine()
  local cfg = (require("organ").config.export or {}).pdf or {}
  return cfg.engine or "pdflatex"
end

local function basename_no_ext(path)
  local name = vim.fn.fnamemodify(path, ":t:r")
  if name == "" then
    name = "document"
  end
  return name
end

-- Run the compile twice so cross-references / table-of-contents land
-- on the second pass.  pdflatex emits the same warnings either way;
-- only the second invocation's exit status matters.
local function run_engine(engine, tex_path, tmpdir)
  local args = {
    engine,
    "-interaction=nonstopmode",
    "-halt-on-error",
    "-output-directory",
    tmpdir,
    tex_path,
  }
  local last_result
  for _ = 1, 2 do
    last_result = vim.system(args, { text = true }):wait()
    if last_result.code ~= 0 then
      return last_result
    end
  end
  return last_result
end

function M.export_buffer_to_file(bufnr, path, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  if not path or path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return nil, "no buffer name; specify a path"
    end
    path = name:gsub("%.org$", "") .. ".pdf"
  end
  local engine = opts.engine or default_engine()
  if vim.fn.executable(engine) ~= 1 then
    return nil, "LaTeX engine not in PATH: " .. engine .. " (configure via export.pdf.engine)"
  end
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local stem = basename_no_ext(path)
  local tex_path = tmpdir .. "/" .. stem .. ".tex"
  -- Render LaTeX from the buffer.
  local tex_source = require("organ.export.latex").export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(tex_path, tex_source)
  if not ok then
    pcall(vim.fn.delete, tmpdir, "rf")
    return nil, "could not write LaTeX source: " .. tostring(werr)
  end
  local result = run_engine(engine, tex_path, tmpdir)
  if result.code ~= 0 then
    local log_path = tmpdir .. "/" .. stem .. ".log"
    local hint = vim.fn.filereadable(log_path) == 1 and (" (log: " .. log_path .. ")") or ""
    -- Don't delete tmpdir on failure: the user needs the log to
    -- diagnose.  Leave it on disk; vim.fn.tempname() roots it under
    -- the per-process temp tree, which the OS cleans up on shutdown.
    return nil, engine .. " exited " .. result.code .. hint
  end
  local pdf_src = tmpdir .. "/" .. stem .. ".pdf"
  if vim.fn.filereadable(pdf_src) == 0 then
    pcall(vim.fn.delete, tmpdir, "rf")
    return nil, engine .. " produced no PDF (check the LaTeX source for errors)"
  end
  -- Move the .pdf into place.
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local copy_ok = pcall(function()
    return vim.uv.fs_copyfile(pdf_src, path)
  end)
  pcall(vim.fn.delete, tmpdir, "rf")
  if not copy_ok or vim.fn.filereadable(path) == 0 then
    return nil, "could not copy compiled PDF to " .. path
  end
  return path
end

-- For symmetry with the other export modules; exports just run
-- export_buffer_to_file with a temp path and return the PDF bytes.
-- Rarely useful (PDF is binary; most callers want a file).
function M.export_buffer(bufnr, opts)
  local tmp = vim.fn.tempname() .. ".pdf"
  local path, err = M.export_buffer_to_file(bufnr, tmp, opts)
  if not path then
    return nil, err
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, "could not read compiled PDF: " .. path
  end
  local bytes = f:read("*a")
  f:close()
  pcall(vim.fn.delete, path)
  return bytes
end

return M
