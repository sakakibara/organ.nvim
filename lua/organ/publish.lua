-- Multi-file project publishing.
--
-- Configured via config.publish.projects:
--
--   publish = {
--     projects = {
--       blog = {
--         base_directory       = "~/org/blog",
--         publishing_directory = "~/public_html/blog",
--         publishing_function  = "html",   -- or "markdown" | "latex" | "ascii" | "beamer"
--                                          -- or function(src_path, dst_path)
--         recursive            = true,     -- default true
--         exclude              = "draft/", -- Lua pattern; nil = no exclusion
--         with_sitemap         = true,     -- emit sitemap.<ext> at output root
--       },
--     },
--   }

local M = {}

local EXT = {
  html = "html",
  markdown = "md",
  latex = "tex",
  beamer = "tex",
  ascii = "txt",
  ics = "ics",
}

local BACKENDS = {
  html = "organ.export.html",
  markdown = "organ.export.markdown",
  latex = "organ.export.latex",
  beamer = "organ.export.beamer",
  ascii = "organ.export.ascii",
  ics = "organ.export.ics",
}

local function get_cfg()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return require("organ.buf_config").read(nil, "publish") or {}
end

local function expand(p)
  return vim.fn.expand(p or "")
end

-- Walk base_directory; collect .org files (recursive by default).
-- Symlinks are followed; a `seen` set keyed by realpath defuses loops
-- (e.g. base/x -> base).
local function walk_org_files(base, recursive, exclude)
  local out = {}
  local seen = {}
  local function visit(d, rel)
    local real = vim.uv.fs_realpath(d) or d
    if seen[real] then
      return
    end
    seen[real] = true
    local h = vim.uv.fs_scandir(d)
    if not h then
      return
    end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      if not name:match("^%.") then
        local sub_rel = rel == "" and name or (rel .. "/" .. name)
        local path = d .. "/" .. name
        if t == "link" then
          local st = vim.uv.fs_stat(path)
          t = st and st.type or t
        end
        if exclude and sub_rel:match(exclude) then
          -- skip
        elseif t == "directory" then
          if recursive then
            visit(path, sub_rel)
          end
        elseif t == "file" and name:match("%.org$") then
          out[#out + 1] = { abs = path, rel = sub_rel }
        end
      end
    end
  end
  visit(base, "")
  table.sort(out, function(a, b)
    return a.rel < b.rel
  end)
  return out
end

local function ensure_dir(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
end

local function publish_one_file(src, dst, fn_spec)
  if type(fn_spec) == "function" then
    return fn_spec(src, dst)
  end
  local backend_name = BACKENDS[fn_spec]
  if not backend_name then
    return nil, "unknown publishing_function: " .. tostring(fn_spec)
  end
  local backend = require(backend_name)
  local fd_in = io.open(src, "r")
  if not fd_in then
    return nil, "open src: " .. src
  end
  local body = fd_in:read("*a")
  fd_in:close()
  local out = backend.export(body)
  ensure_dir(dst)
  local fd_out, err = io.open(dst, "w")
  if not fd_out then
    return nil, err
  end
  fd_out:write(out)
  fd_out:close()
  return dst
end

local function emit_sitemap(out_dir, fn_spec, files)
  local ext = EXT[fn_spec] or "txt"
  local lines = { "* Sitemap", "" }
  for _, rec in ipairs(files) do
    local rel_out = rec.rel:gsub("%.org$", "." .. ext)
    lines[#lines + 1] = "- [[" .. rel_out .. "][" .. rec.rel .. "]]"
  end
  local sitemap_org = out_dir .. "/sitemap.org"
  ensure_dir(sitemap_org)
  local fd = io.open(sitemap_org, "w")
  if fd then
    fd:write(table.concat(lines, "\n") .. "\n")
    fd:close()
  end
  -- Render the sitemap into the same backend.
  local sitemap_dst = out_dir .. "/sitemap." .. ext
  local _, err = publish_one_file(sitemap_org, sitemap_dst, fn_spec)
  if err then
    return nil, err
  end
  return sitemap_dst
end

-- Publish a single project by name. Returns { ok = N_ok, errors = { ... } }.
function M.publish(name)
  local cfg = get_cfg()
  local projects = cfg.projects or {}
  local proj = projects[name]
  if not proj then
    return nil, "no project named '" .. tostring(name) .. "'"
  end
  local base = expand(proj.base_directory)
  local out_dir = expand(proj.publishing_directory)
  if base == "" or out_dir == "" then
    return nil, "project '" .. name .. "' missing base_directory or publishing_directory"
  end
  local recursive = proj.recursive ~= false
  local fn_spec = proj.publishing_function or "html"
  local ext = EXT[fn_spec] or "txt"

  local files = walk_org_files(base, recursive, proj.exclude)
  local ok, errors = 0, {}
  for _, rec in ipairs(files) do
    local dst = out_dir .. "/" .. rec.rel:gsub("%.org$", "." .. ext)
    local _, err = publish_one_file(rec.abs, dst, fn_spec)
    if err then
      errors[#errors + 1] = rec.rel .. ": " .. err
    else
      ok = ok + 1
    end
  end

  local sitemap_path
  if proj.with_sitemap then
    local p, err = emit_sitemap(out_dir, fn_spec, files)
    sitemap_path = p
    if err then
      errors[#errors + 1] = "sitemap: " .. err
    end
  end

  return { ok = ok, total = #files, errors = errors, sitemap = sitemap_path }
end

function M.publish_all()
  local cfg = get_cfg()
  local results = {}
  for name in pairs(cfg.projects or {}) do
    results[name] = (function()
      local r, err = M.publish(name)
      return r or { errors = { err } }
    end)()
  end
  return results
end

function M.list_projects()
  local cfg = get_cfg()
  local out = {}
  for name in pairs(cfg.projects or {}) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

-- Run M.publish on a named project; report a counts-and-errors summary.
local function run_publish_named(name)
  local result, err = M.publish(name)
  if not result then
    require("organ.notify").error("organ: publish failed: " .. tostring(err))
    return
  end
  require("organ.notify").info(
    ("published %d/%d files (%d error%s)"):format(
      result.ok,
      result.total,
      #result.errors,
      #result.errors == 1 and "" or "s"
    )
  )
  for _, e in ipairs(result.errors) do
    require("organ.notify").warn(e)
  end
end

M.commands = {
  publish = {
    fn = function(cmd)
      local name = cmd.args ~= "" and cmd.args or nil
      if not name then
        local projects = M.list_projects()
        if #projects == 0 then
          require("organ.notify").warn("no projects configured (config.publish.projects)")
          return
        end
        vim.ui.select(projects, { prompt = "Publish project:" }, function(choice)
          if choice then
            run_publish_named(choice)
          end
        end)
        return
      end
      run_publish_named(name)
    end,
    nargs = "?",
    complete = function()
      return M.list_projects()
    end,
    desc = "Publish a configured project (no arg: picker)",
  },
  publish_all = {
    fn = function()
      local results = M.publish_all()
      for name, r in pairs(results) do
        require("organ.notify").info(("%s: %d/%d ok"):format(name, r.ok or 0, r.total or 0))
      end
    end,
    desc = "Publish every configured project",
  },
}

return M
