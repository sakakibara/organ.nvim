-- Optional file-type icons for picker rows.
--
-- Progressive enhancement: prefer mini.icons (newer, no Nerd Font
-- requirement when text style is selected), fall back to
-- nvim-web-devicons.  When neither is loaded, returns nil so the
-- caller skips the icon segment entirely.
--
-- Cached per-extension because both back-ends already cache, but the
-- `pcall(require, ...)` lookup itself is cheap-but-not-free, and a
-- picker may build hundreds of items in a single render.

local M = {}

local _backend -- "mini" | "devicons" | false  (false = decided absent)

local function backend()
  if _backend ~= nil then
    return _backend
  end
  local ok = pcall(require, "mini.icons")
  if ok then
    _backend = "mini"
    return _backend
  end
  ok = pcall(require, "nvim-web-devicons")
  if ok then
    _backend = "devicons"
    return _backend
  end
  _backend = false
  return _backend
end

-- Reset the backend cache.  Tests use this between cases to swap
-- between mini.icons and nvim-web-devicons mocks.
function M._reset_cache()
  _backend = nil
end

-- Look up an icon for `path`.  Returns (icon_text, hl_group) or nil
-- when no provider is available.
--
-- `category` is optional; defaults to "file".  Pass "directory" for
-- folders or "filetype" with `path` set to the filetype name to look
-- up by ft instead of by extension.
function M.get(path, category)
  local b = backend()
  if not b then
    return nil
  end
  category = category or "file"
  if b == "mini" then
    local mi = require("mini.icons")
    local icon, hl = mi.get(category, path)
    return icon, hl
  end
  -- nvim-web-devicons
  local dev = require("nvim-web-devicons")
  if category == "directory" then
    local icon, hl = dev.get_icon("folder", "folder", { default = true })
    return icon, hl
  end
  if category == "filetype" then
    local icon, hl = dev.get_icon_by_filetype(path, { default = true })
    return icon, hl
  end
  -- Default: by file path.  devicons resolves on basename + extension.
  local name = vim.fn.fnamemodify(path, ":t")
  local ext = vim.fn.fnamemodify(path, ":e")
  local icon, hl = dev.get_icon(name, ext, { default = true })
  return icon, hl
end

-- Convenience: build the {icon, hl} segment pair (or nil) for use in
-- picker display_segments lists.  Includes a single trailing space so
-- the icon hugs the next column.
function M.segment(path, category)
  local icon, hl = M.get(path, category)
  if not icon then
    return nil
  end
  return { icon .. " ", hl }
end

return M
