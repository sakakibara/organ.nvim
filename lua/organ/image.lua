-- Image reveal for organ.nvim.
--
-- Tier A (universal): open `[[file:image.png]]` under cursor in the system
--   default viewer (`open` on macOS, `xdg-open` on Linux, `start` on
--   Windows). Works in any terminal.
--
-- Tier B (opt-in): when `image.nvim` is installed and `image.inline = true`,
--   render the image inline above the cursor line via image.nvim. Falls
--   back to Tier A silently if image.nvim isn't available.

local M = {}

local IMAGE_EXTS = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  bmp = true,
  tiff = true,
  tif = true,
  svg = true,
}

local function is_image_path(path)
  if not path or path == "" then
    return false
  end
  local ext = path:match("%.([%w]+)$")
  return ext ~= nil and IMAGE_EXTS[ext:lower()] == true
end

-- Find the link target under the cursor.  Recognises:
--   [[file:path][desc]]
--   [[./path]]
--   [[/abs/path]]
--   [[~/path]]
-- Returns the (resolved) path or nil.
local function link_target_at_cursor(bufnr)
  bufnr = bufnr or 0
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local s = 1
  while true do
    local lo = line:find("%[%[", s)
    if not lo then
      return nil
    end
    local hi = line:find("%]%]", lo + 2)
    if not hi then
      return nil
    end
    hi = hi + 1 -- include both ']' chars
    if col + 1 >= lo and col + 1 <= hi then
      local body = line:sub(lo + 2, hi - 2)
      -- `[[target][desc]]` — target is up to the first `][`.
      local target = body:match("^(.-)%]%[") or body
      if not target or target == "" then
        return nil
      end
      target = target:gsub("^file:", "")
      if target:sub(1, 1) == "~" then
        target = vim.fn.expand(target)
      elseif target:sub(1, 1) == "/" then
        -- already absolute
      elseif target:sub(1, 2) == "./" or target:sub(1, 3) == "../" then
        local cur_dir = vim.fn.expand("%:p:h")
        target = vim.fn.fnamemodify(cur_dir .. "/" .. target, ":p")
      elseif target:match("^[a-zA-Z][a-zA-Z0-9+.-]*://") then
        -- URL — leave alone
      else
        -- bare relative path
        local cur_dir = vim.fn.expand("%:p:h")
        target = vim.fn.fnamemodify(cur_dir .. "/" .. target, ":p")
      end
      return target
    end
    s = hi + 1
  end
end

local function open_in_system(path)
  local opener
  if vim.fn.has("mac") == 1 then
    opener = { "open", path }
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    opener = { "cmd.exe", "/c", "start", "", path }
  else
    opener = { "xdg-open", path }
  end
  if vim.fn.executable(opener[1]) ~= 1 then
    require("organ.notify").error("no system opener found (" .. opener[1] .. ")")
    return false
  end
  vim.system(opener, { detach = true })
  return true
end

-- Public: open the image-link target under cursor in the system viewer.
function M.reveal(bufnr)
  bufnr = bufnr or 0
  local target = link_target_at_cursor(bufnr)
  if not target then
    require("organ.notify").warn("no link under cursor")
    return
  end
  if not is_image_path(target) then
    require("organ.notify").info("organ: target is not an image: " .. target)
    -- Still try to open; system viewer can handle other file types too.
  end
  if not vim.loop.fs_stat(target) then
    require("organ.notify").error("organ: file not found: " .. target)
    return
  end

  local cfg = (require("organ.buf_config").read(nil, "image") or {})
  if cfg.inline then
    local ok, image = pcall(require, "image")
    if ok and image then
      pcall(function()
        local img = image.from_file(target, {
          window = vim.api.nvim_get_current_win(),
          buffer = bufnr,
          inline = true,
        })
        if img then
          img:render()
        end
      end)
      return
    end
    require("organ.notify").info("image.nvim not available; falling back to system viewer")
  end
  open_in_system(target)
end

-- Per-buffer state for buffer-wide inline image rendering.
-- bufnr -> { images = { image_handles... }, ns = extmark_ns_id }
local _inline_state = {}

local function resolve_target(target, bufnr)
  if not target or target == "" then
    return nil
  end
  target = target:gsub("^file:", "")
  if target:sub(1, 1) == "~" then
    return vim.fn.expand(target)
  elseif target:sub(1, 1) == "/" then
    return target
  elseif target:sub(1, 2) == "./" or target:sub(1, 3) == "../" then
    local cur_dir = vim.fn.expand("%:p:h")
    return vim.fn.fnamemodify(cur_dir .. "/" .. target, ":p")
  elseif target:match("^[a-zA-Z][a-zA-Z0-9+.-]*://") then
    return nil -- URLs aren't loaded inline
  end
  local cur_dir = vim.fn.expand("%:p:h")
  return vim.fn.fnamemodify(cur_dir .. "/" .. target, ":p")
end

-- Walk the buffer for image-link occurrences. Returns a list of
-- { row (0-based), col (byte), target (resolved abs path) }.
local function find_image_links(bufnr)
  local out = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, ln in ipairs(lines) do
    local pos = 1
    while true do
      local s, e, body = ln:find("%[%[([^%]]+)%]%]", pos)
      if not s then
        break
      end
      local target = body:match("^(.-)%]%[") or body
      local resolved = resolve_target(target, bufnr)
      if resolved and is_image_path(resolved) and vim.loop.fs_stat(resolved) then
        out[#out + 1] = { row = i - 1, col = s - 1, target = resolved }
      end
      pos = e + 1
    end
  end
  return out
end

-- Render every image-link in the buffer inline via image.nvim. Falls back
-- to extmark virt_text "[image: path]" markers when image.nvim is not
-- loaded, so the toggle is still useful in basic terminals.
function M.show_inline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.hide_inline(bufnr)
  local links = find_image_links(bufnr)
  if #links == 0 then
    return 0
  end

  local ok, image_lib = pcall(require, "image")
  local ns = vim.api.nvim_create_namespace("organ_inline_images")
  local state = { images = {}, ns = ns }
  _inline_state[bufnr] = state

  local win = vim.api.nvim_get_current_win()
  for _, lk in ipairs(links) do
    if ok and image_lib then
      pcall(function()
        local img = image_lib.from_file(lk.target, {
          window = win,
          buffer = bufnr,
          x = 0,
          y = lk.row + 1,
          inline = true,
        })
        if img then
          img:render()
          state.images[#state.images + 1] = img
        end
      end)
    else
      -- Fallback marker: virtual text below the link line.
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lk.row, 0, {
        virt_lines = {
          {
            {
              "  [image: " .. vim.fn.fnamemodify(lk.target, ":t") .. "]",
              "Comment",
            },
          },
        },
        virt_lines_above = false,
      })
    end
  end
  return #links
end

function M.hide_inline(bufnr)
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

function M.toggle_inline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if _inline_state[bufnr] then
    M.hide_inline(bufnr)
    return false
  end
  return M.show_inline(bufnr) > 0
end

-- Expose helpers for tests + for callers that want to reuse the resolution
-- logic (e.g. a future :Org follow_link that decides what to do based on the
-- target type).
M._is_image_path = is_image_path
M._link_target_at_cursor = link_target_at_cursor

M.commands = {
  image_reveal = {
    fn = function()
      M.reveal(0)
    end,
    desc = "Open the [[file:image]] link at cursor in the system viewer",
  },
  toggle_inline_images = {
    fn = function()
      local on = M.toggle_inline(0)
      require("organ.notify").info("organ: inline images " .. (on and "ON" or "OFF"))
    end,
    desc = "Toggle inline rendering of every [[file:image]] link in the buffer",
  },
}

return M
