-- PDF exporter for org buffers.
--
-- Default engine ("lua"): renders directly via organ.pdf, no LaTeX
-- toolchain required.  Pure-Lua TTF embed + content streams; picks up a
-- system font automatically (override via opts.font_path /
-- opts.mono_font_path).
--
-- LaTeX engines (pdflatex / xelatex / lualatex): preserved for users
-- who want LaTeX typography, math, or specific package support.  The
-- buffer is rendered to .tex via organ.export.latex, then the chosen
-- engine is invoked twice (so cross-references settle) and the
-- resulting .pdf is moved into place.  The .tex source and engine logs
-- live in a temp directory; only the .pdf is exposed.

local M = {}

local function default_engine()
  local cfg = (require("organ.buf_config").read(nil, "export") or {}).pdf or {}
  return cfg.engine or "lua"
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

local function via_latex_engine(bufnr, path, opts, engine)
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

-- Build the PDF bytes for a buffer via the pure-Lua engine.  Honors
-- the SETUPFILE/INCLUDE expansion knob; all other opts pass straight
-- through to organ.pdf.render (page_width / page_height / margins /
-- font_path / mono_font_path / default_font_size).
local function lua_engine_bytes(bufnr, opts)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local prepare = require("organ.export.prepare")
  lines = prepare.expand(lines, opts)
  local aok, ast = pcall(prepare.ast, lines, opts, "pdf")
  if not aok then
    return nil, tostring(ast)
  end
  local bytes, rerr = require("organ.pdf").render(ast, opts)
  if not bytes then
    return nil, "export.pdf (lua engine): " .. tostring(rerr)
  end
  return bytes
end

local function via_lua_engine(bufnr, path, opts)
  local bytes, err = lua_engine_bytes(bufnr, opts)
  if not bytes then
    return nil, err
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local wok, werr = require("organ.path").write_atomic(path, bytes)
  if not wok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
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
  if engine == "lua" then
    return via_lua_engine(bufnr, path, opts)
  end
  return via_latex_engine(bufnr, path, opts, engine)
end

-- For symmetry with the other export modules; returns the PDF bytes.
-- Under the lua engine this is the natural shape (render produces
-- bytes directly).  Under a LaTeX engine we round-trip through a temp
-- file because the engine writes to disk.
function M.export_buffer(bufnr, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  local engine = opts.engine or default_engine()
  if engine == "lua" then
    return lua_engine_bytes(bufnr, opts)
  end
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
