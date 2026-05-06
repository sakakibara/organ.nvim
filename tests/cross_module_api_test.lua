-- Static cross-module API audit: every `require("organ.foo").bar()` call
-- (whether inline or via local binding) must reference a function `bar`
-- actually defined in `lua/organ/foo.lua`. Catches the bug class that
-- caused `holidays.load_calendar` to crash schedule/deadline (calendar.lua
-- called a function that never existed in holidays.lua).
--
-- Run via: nvim --headless -l tests/cross_module_api_test.lua

local function read(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function strip_comments(body)
  body = body:gsub("%-%-%[%[.-%]%]", "")
  body = body:gsub("%-%-[^\n]*", "")
  return body
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

-- Walk lua/organ/ recursively
local function lua_files()
  local out = {}
  local function walk(dir)
    local fd = vim.uv.fs_scandir(dir)
    if not fd then
      return
    end
    while true do
      local name, t = vim.uv.fs_scandir_next(fd)
      if not name then
        break
      end
      local p = dir .. "/" .. name
      if t == "directory" then
        walk(p)
      elseif name:match("%.lua$") then
        out[#out + 1] = p
      end
    end
  end
  walk("lua/organ")
  return out
end

-- Collect M.<func> defs in a file
local function funcs_in(path)
  local set = {}
  local body = read(path)
  if not body then
    return set
  end
  for fn in body:gmatch("function%s+M%.([%w_]+)") do
    set[fn] = true
  end
  for fn in body:gmatch("M%.([%w_]+)%s*=%s*function") do
    set[fn] = true
  end
  for fn in body:gmatch("M%.([%w_]+)%s*=") do
    set[fn] = true
  end
  return set
end

local function module_to_path(mod)
  local p = "lua/organ/" .. mod:gsub("%.", "/") .. ".lua"
  if exists(p) then
    return p
  end
  local p2 = "lua/organ/" .. mod:gsub("%.", "/") .. "/init.lua"
  if exists(p2) then
    return p2
  end
  return nil
end

local issues = {}
for _, f in ipairs(lua_files()) do
  local body = read(f)
  if body then
    body = strip_comments(body)
    -- Inline FUNCTION-CALL form: require("organ.MOD").func(...)
    -- — must have `(` immediately after the field access; otherwise it's
    -- field access on a table, not a function call.
    for mod, fn in body:gmatch('require%("organ%.([%w%.]+)"%)%s*%.%s*([%w_]+)%s*%(') do
      local target = module_to_path(mod)
      if target then
        local defined = funcs_in(target)
        if not defined[fn] and fn ~= "config" and fn ~= "_state" and fn ~= "_loaded" then
          issues[#issues + 1] = string.format(
            "%s: inline `require(organ.%s).%s(...)` not defined in %s",
            f,
            mod,
            fn,
            target
          )
        end
      end
    end

    -- Local-binding form. Skip 1- and 2-char binding names (likely
    -- aliasing for vim.fn / vim.api, not module-bound) — they'd shadow
    -- other local rebindings of the same name and produce false positives.
    local bindings = {}
    for name, mod in body:gmatch('local%s+([%w_]+)%s*=%s*require%("organ%.([%w%.]+)"%)') do
      if #name >= 3 then
        bindings[name] = mod
      end
    end
    for name, mod in
      body:gmatch('local%s+[%w_]+%s*,%s*([%w_]+)%s*=%s*pcall%(require,%s*"organ%.([%w%.]+)"%)')
    do
      if #name >= 3 then
        bindings[name] = mod
      end
    end
    for name, mod in pairs(bindings) do
      local target = module_to_path(mod)
      if target then
        local defined = funcs_in(target)
        for fn in body:gmatch(name .. "%.([%w_]+)%s*%(") do
          if not fn:match("^_") and fn ~= "config" and not defined[fn] then
            issues[#issues + 1] = string.format(
              "%s: `%s.%s` (via require organ.%s) not defined in %s",
              f,
              name,
              fn,
              mod,
              target
            )
          end
        end
      end
    end
  end
end

if #issues > 0 then
  print("FAILED: cross-module API mismatches:")
  for _, i in ipairs(issues) do
    print("  " .. i)
  end
  os.exit(1)
end
print("cross_module_api_test: PASS (every cross-module call resolves)")
