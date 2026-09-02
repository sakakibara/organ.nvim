-- Resolve a TTF path for PDF embedding.
--
-- Three escalating strategies:
--   1. Explicit `opts.path` override (verified on disk).
--   2. `fc-match` query when fontconfig is installed; its answer is
--      used only when the file carries a TrueType sfnt header.
--   3. Recursive walk of OS-standard font directories, prefering a
--      curated list of well-known faces and falling back to first
--      *.ttf found.
--
-- Returns (path, nil) on success or (nil, diagnostic) where the
-- diagnostic lists every directory that was inspected, so the user
-- can tell whether the search missed a directory or that directory
-- genuinely held no usable file.

local M = {}

local uv = vim.uv or vim.loop

local STYLES = {
  regular = true,
  bold = true,
  italic = true,
  bolditalic = true,
  mono = true,
}

-- Filename preference table, ordered by preference (higher wins).
-- Each style maps to an ordered list of basenames to look for first.
-- Match is case-insensitive against the filename only.
local PREFERRED = {
  regular = {
    "DejaVuSans.ttf",
    "LiberationSans-Regular.ttf",
    "NotoSans-Regular.ttf",
    "FreeSans.ttf",
    "Cantarell-Regular.ttf",
    "Arial.ttf",
    "Helvetica.ttf",
  },
  bold = {
    "DejaVuSans-Bold.ttf",
    "LiberationSans-Bold.ttf",
    "NotoSans-Bold.ttf",
    "FreeSansBold.ttf",
    "Cantarell-Bold.ttf",
    "Arial Bold.ttf",
    "Arial-Bold.ttf",
  },
  italic = {
    "DejaVuSans-Oblique.ttf",
    "LiberationSans-Italic.ttf",
    "NotoSans-Italic.ttf",
    "FreeSansOblique.ttf",
    "Cantarell-Oblique.ttf",
    "Arial Italic.ttf",
    "Arial-Italic.ttf",
  },
  bolditalic = {
    "DejaVuSans-BoldOblique.ttf",
    "LiberationSans-BoldItalic.ttf",
    "NotoSans-BoldItalic.ttf",
    "FreeSansBoldOblique.ttf",
    "Cantarell-BoldOblique.ttf",
    "Arial Bold Italic.ttf",
  },
  mono = {
    "DejaVuSansMono.ttf",
    "LiberationMono-Regular.ttf",
    "NotoSansMono-Regular.ttf",
    "FreeMono.ttf",
    "Cousine-Regular.ttf",
  },
}

local FC_QUERY = {
  regular = ":style=Regular",
  bold = ":weight=bold:style=Bold",
  italic = ":style=Italic",
  bolditalic = ":weight=bold:style=Bold Italic",
  mono = ":spacing=mono",
}

-- OS detection. Returns a list of directories to scan in order.

local function home()
  return vim.env.HOME or (uv.os_homedir and uv.os_homedir()) or ""
end

local function os_font_dirs()
  local sys = (uv.os_uname and uv.os_uname().sysname) or ""
  local h = home()
  if sys == "Darwin" then
    return {
      "/System/Library/Fonts/",
      "/System/Library/Fonts/Supplemental/",
      "/Library/Fonts/",
      h .. "/Library/Fonts/",
    }
  elseif sys:match("^Windows") or sys:match("MINGW") or sys:match("CYGWIN") then
    return {
      "C:/Windows/Fonts/",
    }
  else
    -- Linux / *BSD / fallback.
    return {
      "/usr/share/fonts/truetype/",
      "/usr/share/fonts/TTF/",
      "/usr/share/fonts/",
      "/usr/local/share/fonts/",
      h .. "/.local/share/fonts/",
      h .. "/.fonts/",
    }
  end
end

-- Helpers.

local function file_exists(path)
  if not path or path == "" then
    return false
  end
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

local function dir_exists(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

local function join(dir, name)
  if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
    return dir .. name
  end
  return dir .. "/" .. name
end

-- Walks `dir` up to `depth` levels deep, calling `cb(full_path,
-- name)` for each regular file. Stops early when `cb` returns truthy.
local function walk(dir, depth, cb)
  if depth < 0 then
    return false
  end
  local handle = uv.fs_scandir(dir)
  if not handle then
    return false
  end
  -- Collect entries first so a deterministic order is possible.
  local files, dirs = {}, {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" then
      files[#files + 1] = name
    elseif kind == "directory" then
      dirs[#dirs + 1] = name
    elseif kind == "link" then
      -- Resolve and classify.
      local full = join(dir, name)
      local st = uv.fs_stat(full)
      if st and st.type == "file" then
        files[#files + 1] = name
      elseif st and st.type == "directory" then
        dirs[#dirs + 1] = name
      end
    end
  end
  table.sort(files)
  table.sort(dirs)
  for _, name in ipairs(files) do
    if cb(join(dir, name), name) then
      return true
    end
  end
  for _, name in ipairs(dirs) do
    if walk(join(dir, name), depth - 1, cb) then
      return true
    end
  end
  return false
end

-- Strategy 1: explicit path override.

local function try_explicit(opts)
  local p = opts.path
  if p == nil then
    return nil, nil, false
  end
  if file_exists(p) then
    return p, nil, true
  end
  return nil, ("explicit path does not exist: %s"):format(p), true
end

-- Strategy 2: fc-match.

-- organ.pdf.font embeds TrueType outlines only; fontconfig may answer
-- with a collection (.ttc) or a CFF OpenType face instead.
local function has_truetype_header(path)
  local fh = io.open(path, "rb")
  if not fh then
    return false
  end
  local magic = fh:read(4)
  fh:close()
  return magic == "\0\1\0\0" or magic == "true"
end

local function try_fc_match(style)
  if vim.fn.executable("fc-match") ~= 1 then
    return nil
  end
  local filter = FC_QUERY[style] or FC_QUERY.regular
  local ok, res = pcall(function()
    return vim.system({ "fc-match", "--format=%{file}", filter }, { text = true }):wait()
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local path = (res.stdout or ""):gsub("%s+$", "")
  if path ~= "" and file_exists(path) and has_truetype_header(path) then
    return path
  end
  return nil
end

-- Strategy 3: recursive directory walk.

local function try_dir_walk(style, dirs)
  local preferred = PREFERRED[style] or PREFERRED.regular
  -- Lower-cased lookup for case-insensitive match.
  local prefer_index = {}
  for i, name in ipairs(preferred) do
    prefer_index[name:lower()] = i
  end

  -- Track the best-ranked preferred file across all dirs, plus the
  -- first generic *.ttf as a last-resort fallback.
  local best_rank, best_path = math.huge, nil
  local fallback = nil

  for _, d in ipairs(dirs) do
    if dir_exists(d) then
      walk(d, 3, function(full, name)
        local lname = name:lower()
        if lname:sub(-4) == ".ttf" then
          local rank = prefer_index[lname]
          if rank and rank < best_rank then
            best_rank = rank
            best_path = full
            if rank == 1 then
              -- Top-preferred name found; stop scanning.
              return true
            end
          elseif not fallback then
            fallback = full
          end
        end
        return false
      end)
      if best_rank == 1 then
        break
      end
    end
  end

  return best_path or fallback
end

-- Public surface.

function M.find(opts)
  opts = opts or {}
  local style = opts.style or "regular"
  if not STYLES[style] then
    return nil, ("unknown style: %s"):format(style)
  end

  -- 1. Explicit override.
  local ep, eerr, eused = try_explicit(opts)
  if eused then
    return ep, eerr
  end

  -- 2. fc-match.
  local fc = try_fc_match(style)
  if fc then
    return fc, nil
  end

  -- 3. Directory walk. Route via the module table so tests can stub
  -- the directory list.
  local dirs = M._os_font_dirs()
  local hit = try_dir_walk(style, dirs)
  if hit then
    return hit, nil
  end

  -- Build a diagnostic listing every directory we inspected.
  local tried = {}
  for _, d in ipairs(dirs) do
    local marker = dir_exists(d) and "" or " (missing)"
    tried[#tried + 1] = d .. marker
  end
  local msg = ("no font found; tried: %s"):format(table.concat(tried, ", "))
  return nil, msg
end

-- Exposed for tests.
M._os_font_dirs = os_font_dirs

return M
