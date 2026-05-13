-- LaTeX fragment preview popup.
--
-- Tier A (no external deps): finds the LaTeX fragment under the cursor
--   (`$…$`, `$$…$$`, `\(...\)`, `\[...\]`, `\begin{env}…\end{env}`),
--   expands recognised entities to unicode (using lua/organ/entities.lua),
--   and shows the result in a small floating window.
--
-- Tier B (opt-in): when `latex.preview = "image"` is set and the system
--   has `pdflatex` + `dvipng`, render the fragment to a PNG and dispatch
--   to a user-provided image displayer (config.latex.display_image).

local M = {}

local obuf = require("organ.buf")
local FRAGMENT_PATTERNS = {
  -- (start_marker, end_marker, kind)
  { "\\%[", "\\%]", "display" },
  { "\\%(", "\\%)", "inline" },
  { "%$%$", "%$%$", "display" },
  { "%$", "%$", "inline" },
}

-- Detect a `\begin{env}...\end{env}` block spanning multiple lines that
-- contains `lnum`.  Returns start_lnum, end_lnum or nil.
local function find_environment(lines, lnum)
  -- Scan backwards from cursor for the nearest \begin without an
  -- intervening \end.  If we find one before any \end, we may be inside
  -- an environment.
  local start_lnum, env_name
  for i = lnum, 1, -1 do
    local l = lines[i] or ""
    local n = l:match("\\begin{([^}]+)}")
    if n then
      start_lnum = i
      env_name = n
      break
    end
    if l:match("\\end{[^}]+}") and i ~= lnum then
      return nil
    end
  end
  if not start_lnum then
    return nil
  end
  -- Scan forward for matching \end.
  for i = start_lnum, #lines do
    local l = lines[i] or ""
    if l:match("\\end{" .. env_name .. "}") then
      if i >= lnum then
        return start_lnum, i, "environment"
      end
      return nil
    end
  end
  return nil
end

-- Locate the LaTeX fragment containing column `col` on `line`.  Returns
-- start/end byte cols and the fragment string, or nil if not in one.
local function find_inline_fragment(line, col)
  for _, p in ipairs(FRAGMENT_PATTERNS) do
    local s = 1
    while true do
      local lo, hi = line:find(p[1], s)
      if not lo then
        break
      end
      local close_lo, close_hi = line:find(p[2], hi + 1)
      if close_lo and col + 1 >= lo and col + 1 <= close_hi then
        return lo, close_hi, line:sub(lo, close_hi), p[3]
      end
      s = hi + 1
    end
  end
end

-- Public: find the fragment at the buffer cursor.  Returns a table
-- describing it, or nil.
function M.fragment_at_cursor(bufnr)
  bufnr = bufnr or 0
  local cur = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cur[1], cur[2]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local env_start, env_end = find_environment(lines, lnum)
  if env_start and env_end then
    return {
      kind = "environment",
      start_line = env_start,
      end_line = env_end,
      text = table.concat(vim.list_slice(lines, env_start, env_end), "\n"),
    }
  end

  local line = lines[lnum] or ""
  local lo, hi, text, kind = find_inline_fragment(line, col)
  if lo then
    return {
      kind = kind,
      start_line = lnum,
      end_line = lnum,
      start_col = lo - 1,
      end_col = hi,
      text = text,
    }
  end
end

-- Pretty-print the fragment by replacing recognised \name entities
-- with their unicode counterparts.  Falls back to the raw text.
local function pretty(text)
  local entities = require("organ.entities")
  local function replace(seq)
    local glyph = entities.lookup(seq)
    return glyph or seq
  end
  return (text:gsub("(\\[A-Za-z]+)", replace))
end

local function open_popup(lines, title)
  local buf = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(buf, 0, -1, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local width = 0
  for _, l in ipairs(lines) do
    if vim.fn.strdisplaywidth(l) > width then
      width = vim.fn.strdisplaywidth(l)
    end
  end
  -- Bigger by default: at least 40 cols, target 60% width when content
  -- is short. Caps at columns - 4 so the border stays inside the screen.
  width = math.min(math.max(width + 4, 40, math.floor(vim.o.columns * 0.4)), vim.o.columns - 4)
  local height = math.min(math.max(#lines + 1, 5), vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = "rounded",
    title = title or " LaTeX ",
    title_pos = "center",
    style = "minimal",
  })
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  -- Footer: q-to-close hint via winbar (style=minimal still allows it).
  pcall(function()
    require("organ.ui").set_winbar(win, { { "q", "close" } }, { title = "LaTeX preview" })
  end)
  -- Auto-close on cursor moved out of the source position.
  vim.api.nvim_create_autocmd("CursorMoved", {
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  return win
end

-- Try to render `frag` to PNG and display via image.nvim. Returns true on
-- success, false if image.nvim isn't loaded or anything fails.
local function try_image_render(bufnr, frag)
  local ok_img, image_lib = pcall(require, "image")
  if not ok_img or not image_lib then
    return false
  end
  local renderer = require("organ.latex_render")
  local ok_tools = renderer.have_tools()
  if not ok_tools then
    return false
  end

  local cfg = ((require("organ").config or {}).latex or {})
  local png, err = renderer.render(frag.text, {
    kind = frag.kind,
    dpi = cfg.dpi,
    fg = cfg.foreground,
    preamble = cfg.preamble,
  })
  if not png then
    require("organ.notify").warn("LaTeX render: " .. (err or "unknown"))
    return false
  end

  local ok_render = pcall(function()
    local img = image_lib.from_file(png, {
      window = vim.api.nvim_get_current_win(),
      buffer = bufnr,
      x = 0,
      y = (frag.start_line or 1),
      inline = true,
    })
    if img then
      img:render()
    end
  end)
  return ok_render
end

-- Public: open the preview popup for the fragment at cursor.
function M.open(bufnr)
  bufnr = bufnr or 0
  local frag = M.fragment_at_cursor(bufnr)
  if not frag then
    require("organ.notify").info("no LaTeX fragment at cursor")
    return nil
  end

  local cfg = ((require("organ").config or {}).latex or {})
  if cfg.preview == "image" and try_image_render(bufnr, frag) then
    return nil
  end

  local body = pretty(frag.text)
  local lines = vim.split(body, "\n", { plain = true })
  local title = string.format(" LaTeX (%s) ", frag.kind)
  return open_popup(lines, title)
end

-- Buffer-wide inline LaTeX image rendering (toggle).
-- bufnr -> { images = {...}, ns = ns_id }
local _inline_state = {}

-- Find every fragment in the buffer. Returns a list of frag tables (same
-- shape as fragment_at_cursor's result).
local function all_fragments(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}

  -- Environments: walk for paired \begin{X}...\end{X}.
  local i = 1
  while i <= #lines do
    local l = lines[i] or ""
    local env = l:match("\\begin{([^}]+)}")
    if env then
      local end_i
      for j = i, #lines do
        if (lines[j] or ""):match("\\end{" .. env .. "}") then
          end_i = j
          break
        end
      end
      if end_i then
        out[#out + 1] = {
          kind = "environment",
          start_line = i,
          end_line = end_i,
          text = table.concat(vim.list_slice(lines, i, end_i), "\n"),
        }
        i = end_i + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- Inline + display patterns within single lines.
  for ln_i, line in ipairs(lines) do
    for _, p in ipairs(FRAGMENT_PATTERNS) do
      local s = 1
      while true do
        local lo, hi = line:find(p[1], s)
        if not lo then
          break
        end
        local close_lo, close_hi = line:find(p[2], hi + 1)
        if not close_lo then
          break
        end
        out[#out + 1] = {
          kind = p[3],
          start_line = ln_i,
          end_line = ln_i,
          start_col = lo - 1,
          end_col = close_hi,
          text = line:sub(lo, close_hi),
        }
        s = close_hi + 1
      end
    end
  end

  return out
end

function M.show_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.hide_all(bufnr)

  local renderer = require("organ.latex_render")
  local ok_tools, missing = renderer.have_tools()
  if not ok_tools then
    require("organ.notify").error("LaTeX inline render needs: " .. table.concat(missing, ", "))
    return 0
  end
  local ok_img, image_lib = pcall(require, "image")
  if not ok_img or not image_lib then
    require("organ.notify").error("image.nvim required for inline LaTeX rendering")
    return 0
  end

  local cfg = ((require("organ").config or {}).latex or {})
  local frags = all_fragments(bufnr)
  if #frags == 0 then
    return 0
  end

  local ns = vim.api.nvim_create_namespace("organ_inline_latex")
  local state = { images = {}, ns = ns }
  _inline_state[bufnr] = state
  local win = vim.api.nvim_get_current_win()

  for _, frag in ipairs(frags) do
    local png, err = renderer.render(frag.text, {
      kind = frag.kind,
      dpi = cfg.dpi,
      fg = cfg.foreground,
      preamble = cfg.preamble,
    })
    if png then
      pcall(function()
        local img = image_lib.from_file(png, {
          window = win,
          buffer = bufnr,
          x = 0,
          y = frag.start_line,
          inline = true,
        })
        if img then
          img:render()
          state.images[#state.images + 1] = img
        end
      end)
    elseif err then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, frag.start_line - 1, 0, {
        virt_lines = { { { "  [latex error: " .. err .. "]", "ErrorMsg" } } },
      })
    end
  end
  return #frags
end

function M.hide_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = _inline_state[bufnr]
  if not state then
    return
  end
  for _, img in ipairs(state.images or {}) do
    pcall(function()
      img:clear()
    end)
  end
  if state.ns then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.ns, 0, -1)
  end
  _inline_state[bufnr] = nil
end

function M.toggle_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if _inline_state[bufnr] then
    M.hide_all(bufnr)
    return false
  end
  return M.show_all(bufnr) > 0
end

M._all_fragments = all_fragments

M.commands = {
  latex_preview = {
    fn = function()
      M.open(0)
    end,
    desc = "Show LaTeX fragment at cursor in a popup (with entity expansion)",
  },
  latex_render = {
    fn = function()
      local on = M.toggle_all(0)
      require("organ.notify").info("LaTeX inline render: " .. (on and "on" or "off"))
    end,
    desc = "Toggle inline image rendering of every LaTeX fragment in the buffer",
  },
}

return M
