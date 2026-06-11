-- Static convention audit: indexer stores line_start as a 0-based row
-- (it comes from tree-sitter's :range()), but humans count from 1, and
-- nvim_win_set_cursor uses 1-based rows. So every site that displays a
-- line number to the user OR positions the cursor based on line_start
-- MUST add 1.
--
-- We caught one round of off-by-ones in agenda + backlinks via manual
-- review; this test pins the convention so future code can't reintroduce
-- the bug class.
--
-- Pattern matched as risky:
--   - `nvim_win_set_cursor(_, { X.line_start, ` (raw 0-based to 1-based API)
--   - `tostring(X.line_start ...)` in display contexts (would show off-by-one)
-- Pattern matched as OK:
--   - `X.line_start + 1`
--   - `(X.line_start or N) + 1`
--   - source-of-truth uses (indexer storage, hash inputs, query SELECT)
--
-- Run via: nvim --headless -l tests/line_number_convention_test.lua

local function read(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local s = fh:read("*a")
  fh:close()
  return s
end

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

-- Files that legitimately store/manipulate raw 0-based rows (not display).
local ALLOWLIST = {
  ["lua/organ/indexer.lua"] = true, -- writes raw rows to DB
  ["lua/organ/walk.lua"] = true, -- iterates tree-sitter ranges
}

local issues = {}

for _, f in ipairs(lua_files()) do
  if not ALLOWLIST[f] then
    local body = read(f)
    if body then
      for line_no, line in
        (function()
          local i = 0
          return function()
            i = i + 1
            local nl = body:find("\n", 1, true)
            if not nl then
              return nil
            end
            local one = body:sub(1, nl - 1)
            body = body:sub(nl + 1)
            if one == "" and body == "" then
              return nil
            end
            return i, one
          end
        end)()
      do
        -- Skip comment lines
        if not line:match("^%s*%-%-") then
          -- Risky: cursor positioning from line_start without +1
          if line:match("nvim_win_set_cursor%([^,]+,%s*{[%w_.]*line_start%s*,") then
            if not line:match("line_start%s*%+%s*1") and not line:match("or%s+%d+%)%s*%+%s*1") then
              issues[#issues + 1] = string.format(
                "%s:%d: cursor set with raw line_start (0-based; nvim API is 1-based)\n  %s",
                f,
                line_no,
                line
              )
            end
          end

          -- Risky: display interpolation tostring(<>line_start...)
          if line:match("tostring%([^)]*line_start[^)]*%)") then
            if not line:match("line_start%s*%+%s*1") and not line:match("or%s+%d+%)%s*%+%s*1") then
              -- Whitelist the indexer ID hash function
              if not line:match('#L"') then
                issues[#issues + 1] = string.format(
                  "%s:%d: tostring(line_start) in display context (should be +1)\n  %s",
                  f,
                  line_no,
                  line
                )
              end
            end
          end
        end
      end
    end
  end
end

if #issues > 0 then
  print("FAILED: line-number convention violations:")
  for _, i in ipairs(issues) do
    print("  " .. i)
  end
  os.exit(1)
end
print("line_number_convention_test: PASS (no raw 0-based line_start in display/cursor contexts)")
