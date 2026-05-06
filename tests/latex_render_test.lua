-- Pure-logic tests for organ.latex_render. We don't shell out to pdflatex
-- here (no toolchain in CI is assumed); instead we cover template build,
-- color conversion, key stability, and have_tools detection.
-- Run via: nvim --headless -l tests/latex_render_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local r = require("organ.latex_render")

-- 1. fg_to_xcolor handles `#RRGGBB`, bare hex, integers, nil.
do
  assert(r._fg_to_xcolor(nil) == nil)
  assert(r._fg_to_xcolor("#aabbcc") == "[HTML]{AABBCC}")
  assert(r._fg_to_xcolor("aabbcc") == "[HTML]{AABBCC}")
  assert(r._fg_to_xcolor(0xff8800) == "[HTML]{FF8800}")
  assert(r._fg_to_xcolor("notacolor") == nil, "garbage should yield nil")
end

-- 2. build_tex wraps inline & display, leaves environment as-is.
do
  local tex = r._build_tex("$x^2$", "inline", nil, nil)
  assert(tex:find("\\begin{document}", 1, true))
  assert(tex:find("\\(x^2\\)", 1, true), "inline body should be wrapped:\n" .. tex)

  tex = r._build_tex("$$\\sum i$$", "display", nil, nil)
  assert(tex:find("\\[\\sum i\\]", 1, true), "display body wrapped:\n" .. tex)

  local env = "\\begin{equation}\nE=mc^2\n\\end{equation}"
  tex = r._build_tex(env, "environment", nil, nil)
  assert(tex:find(env, 1, true), "environment passes through:\n" .. tex)
end

-- 3. Cache key is stable for same input, varies on changes.
do
  local k1 = r._key_for("$x$", "inline", "[HTML]{000000}", 150, "PRE")
  local k2 = r._key_for("$x$", "inline", "[HTML]{000000}", 150, "PRE")
  assert(k1 == k2, "same input → same key")
  assert(k1 ~= r._key_for("$y$", "inline", "[HTML]{000000}", 150, "PRE"))
  assert(k1 ~= r._key_for("$x$", "display", "[HTML]{000000}", 150, "PRE"))
  assert(k1 ~= r._key_for("$x$", "inline", "[HTML]{FF0000}", 150, "PRE"))
  assert(k1 ~= r._key_for("$x$", "inline", "[HTML]{000000}", 300, "PRE"))
end

-- 4. have_tools returns boolean + missing list (don't assert presence).
do
  local ok, missing = r.have_tools()
  assert(type(ok) == "boolean")
  assert(type(missing) == "table")
end

-- 5. render() returns nil + err when tools missing (skip if pdflatex present).
do
  local ok = r.have_tools()
  if not ok then
    local png, err = r.render("$x$", { kind = "inline" })
    assert(png == nil and type(err) == "string", "missing-tools render should return nil + err")
  end
end

-- 6. all_fragments scan finds inline + display + environment in one buffer.
do
  local lp = require("organ.latex_preview")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Inline $a+b$ here.",
    "Display \\[c+d\\] line.",
    "\\begin{equation}",
    "  e = mc^2",
    "\\end{equation}",
    "End.",
  })
  vim.api.nvim_set_current_buf(buf)
  local frags = lp._all_fragments(buf)
  local kinds = {}
  for _, f in ipairs(frags) do
    kinds[f.kind] = (kinds[f.kind] or 0) + 1
  end
  assert((kinds.inline or 0) >= 1, "expected at least one inline; got " .. vim.inspect(kinds))
  assert((kinds.display or 0) >= 1, "expected one display; got " .. vim.inspect(kinds))
  assert((kinds.environment or 0) == 1, "expected one environment; got " .. vim.inspect(kinds))
end

io.write("latex render ok\n")
os.exit(0)
