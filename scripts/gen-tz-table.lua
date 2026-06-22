-- Regenerate lua/organ/todo/timezone_table.lua from a local copy of IANA
-- zone1970.tab.  Portable pure Lua:
--   nvim -l scripts/gen-tz-table.lua path/to/zone1970.tab
-- Maps each IANA zone name to its primary ISO 3166-1 alpha-2 country code (the
-- first of the tab's comma-separated country list).  Run when IANA publishes a
-- new tzdata release (typically 2-4x yearly).  This is a data table.
local src = arg[1] or "zone1970.tab"
local out = arg[2] or "lua/organ/todo/timezone_table.lua"

local rows = {}
for line in io.lines(src) do
  line = (line:gsub("\r$", "")) -- tolerate CRLF source files
  if line:sub(1, 1) ~= "#" then
    local f = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      f[#f + 1] = field
    end
    if #f >= 3 and f[1] ~= "" and f[3] ~= "" then
      local primary = f[1]:match("^([^,]*)")
      rows[#rows + 1] = string.format('  ["%s"] = "%s",', f[3], primary)
    end
  end
end
table.sort(rows)

local o = assert(io.open(out, "w"))
o:write("-- Generated from IANA zone1970.tab by scripts/gen-tz-table.lua.\n")
o:write("-- IANA zone name -> ISO 3166-1 alpha-2 country code (primary country).\n")
o:write("return {\n")
for _, r in ipairs(rows) do
  o:write(r .. "\n")
end
o:write("}\n")
o:close()
print(string.format("wrote %s (%d zones)", out, #rows))
