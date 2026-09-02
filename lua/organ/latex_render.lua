-- Render a LaTeX fragment to a PNG via pdflatex + pdftocairo (or dvipng).
-- Cached on disk by SHA-256 of (fragment, fg color, dpi). Synchronous;
-- cache hits are instant.
--
-- Public API:
--   M.render(text, opts) -> path | nil, err
--   M.have_tools()       -> boolean, missing[]
--   M.cache_dir()        -> string
--   M.purge()            -> count

local M = {}

M._cache_dir = function()
  return vim.fn.stdpath("cache") .. "/organ/latex"
end
function M.cache_dir()
  return M._cache_dir()
end

local function organ_cfg()
  local ok, organ = pcall(require, "organ")
  if not ok then
    return {}
  end
  return (organ.config and require("organ.buf_config").read(nil, "latex")) or {}
end

local function tool(name)
  return vim.fn.executable(name) == 1
end

function M.have_tools()
  local missing = {}
  if not tool("pdflatex") then
    missing[#missing + 1] = "pdflatex"
  end
  if not tool("pdftocairo") and not tool("dvipng") then
    missing[#missing + 1] = "pdftocairo or dvipng"
  end
  return #missing == 0, missing
end

local DEFAULT_PREAMBLE = [[
\documentclass[border=2pt,varwidth]{standalone}
\usepackage[utf8]{inputenc}
\usepackage{amsmath,amssymb,amsthm,amsfonts}
\usepackage{mathtools}
\usepackage{xcolor}
\pagestyle{empty}
]]

-- Build the .tex source for a fragment. Inline (`\(...\)`, `$...$`) and
-- display (`\[...\]`, `$$...$$`) are wrapped in math mode; `environment`
-- kind passes through as-is (already wraps itself).
local function build_tex(text, kind, fg, preamble)
  local body
  if kind == "inline" then
    local stripped = text:match("^%$(.-)%$$") or text:match("^\\%((.*)\\%)$") or text
    body = "\\(" .. stripped .. "\\)"
  elseif kind == "display" then
    local stripped = text:match("^%$%$(.-)%$%$$") or text:match("^\\%[(.*)\\%]$") or text
    body = "\\[" .. stripped .. "\\]"
  else
    body = text
  end
  return (preamble or DEFAULT_PREAMBLE)
    .. "\\color"
    .. (fg or "{black}")
    .. "\n"
    .. "\\begin{document}\n"
    .. body
    .. "\n\\end{document}\n"
end

-- Convert a Neovim highlight color (#RRGGBB string or integer) to the
-- argument of xcolor's `\color` macro: "[HTML]{RRGGBB}", or nil for
-- default black.
local function fg_to_xcolor(fg)
  if not fg then
    return nil
  end
  if type(fg) == "number" then
    fg = string.format("#%06x", fg)
  end
  local hex = fg:match("^#?(%x%x%x%x%x%x)$")
  if not hex then
    return nil
  end
  return "[HTML]{" .. hex:upper() .. "}"
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
  return path
end

-- Cache key: sha of (text + kind + fg + dpi + preamble).
local function key_for(text, kind, fg, dpi, preamble)
  local raw =
    table.concat({ text, kind or "", fg or "", tostring(dpi or 150), preamble or "" }, "\1")
  return vim.fn.sha256(raw):sub(1, 32)
end

-- Run a command, return ok, stdout, stderr.
local function run(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return res.code == 0, res.stdout or "", res.stderr or ""
end

function M.render(text, opts)
  opts = opts or {}
  local kind = opts.kind or "display"
  local cfg = organ_cfg()
  local dpi = opts.dpi or cfg.dpi or 150
  local fg_xcolor = fg_to_xcolor(opts.fg or cfg.foreground)
  local preamble = opts.preamble or cfg.preamble or DEFAULT_PREAMBLE

  local ok_tools, missing = M.have_tools()
  if not ok_tools then
    return nil, "missing tools: " .. table.concat(missing, ", ")
  end

  local cache = ensure_dir(M.cache_dir())
  local key = key_for(text, kind, fg_xcolor or "", dpi, preamble)
  local png = cache .. "/" .. key .. ".png"
  if vim.uv.fs_stat(png) then
    return png
  end

  local work = ensure_dir(cache .. "/work-" .. key)
  local tex_path = work .. "/frag.tex"
  local fh = io.open(tex_path, "w")
  if not fh then
    return nil, "cannot open " .. tex_path
  end
  fh:write(build_tex(text, kind, fg_xcolor, preamble))
  fh:close()

  local ok, _, err = run({
    "pdflatex",
    "-interaction=nonstopmode",
    "-halt-on-error",
    "-output-directory=" .. work,
    tex_path,
  }, work)
  if not ok then
    -- Try to surface the LaTeX log tail for diagnostics.
    local log_path = work .. "/frag.log"
    local logf = io.open(log_path, "r")
    local tail = ""
    if logf then
      local body = logf:read("*a") or ""
      logf:close()
      tail = body:sub(-500)
    end
    return nil, "pdflatex failed: " .. (err ~= "" and err or tail)
  end

  local pdf = work .. "/frag.pdf"
  if not vim.uv.fs_stat(pdf) then
    return nil, "no pdf produced"
  end

  if tool("pdftocairo") then
    ok, _, err = run({
      "pdftocairo",
      "-png",
      "-singlefile",
      "-transp",
      "-r",
      tostring(dpi),
      pdf,
      work .. "/out",
    })
    if ok and vim.uv.fs_stat(work .. "/out.png") then
      vim.uv.fs_rename(work .. "/out.png", png)
    else
      return nil, "pdftocairo failed: " .. err
    end
  else
    -- Fallback: pdf -> dvi -> dvipng. We invoked pdflatex above, so we
    -- need to convert pdf to png via a different path. Use `pdftoppm`
    -- if present, else error out.
    if tool("pdftoppm") then
      ok, _, err = run({
        "pdftoppm",
        "-png",
        "-singlefile",
        "-r",
        tostring(dpi),
        pdf,
        work .. "/out",
      })
      if ok and vim.uv.fs_stat(work .. "/out.png") then
        vim.uv.fs_rename(work .. "/out.png", png)
      else
        return nil, "pdftoppm failed: " .. err
      end
    else
      return nil, "no pdf->png converter (need pdftocairo or pdftoppm)"
    end
  end

  -- Best-effort cleanup of intermediate artefacts. Leave the .png in
  -- the parent cache dir.
  pcall(function()
    for _, ext in ipairs({ "tex", "pdf", "log", "aux" }) do
      vim.uv.fs_unlink(work .. "/frag." .. ext)
    end
    vim.uv.fs_rmdir(work)
  end)

  return png
end

function M.purge()
  local dir = M.cache_dir()
  if not vim.uv.fs_stat(dir) then
    return 0
  end
  local count = 0
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = dir .. "/" .. name
    if t == "file" then
      vim.uv.fs_unlink(path)
      count = count + 1
    elseif t == "directory" then
      -- Stale work dir from an interrupted render.
      pcall(vim.fn.delete, path, "rf")
      count = count + 1
    end
  end
  return count
end

-- Exposed for tests.
M._build_tex = build_tex
M._fg_to_xcolor = fg_to_xcolor
M._key_for = key_for

M.commands = {
  latex_cache_purge = {
    fn = function()
      local n = M.purge()
      require("organ.notify").info("LaTeX cache: removed " .. n .. " entries")
    end,
    desc = "Delete cached LaTeX-fragment PNGs",
  },
}

return M
