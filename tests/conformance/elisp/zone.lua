-- One zone's run of the elisp gate, started by gate.lua with TZ set to
-- the zone named by its argument: the cases whose `tz` header names it,
-- through Emacs and organ in this process's zone.  Prints "zone calls
-- NAME..." (the builtins its cases called) and "zone ok CASES RECORDED",
-- or the problems, and exits accordingly.

local root = vim.fn.getcwd()
local runner = dofile(root .. "/tests/conformance/_runner.lua")
local area = dofile(root .. "/tests/conformance/elisp/organ.lua")
local zone = arg[1]

local ok, problems, info = runner.run("elisp", {
  tz = zone,
  select = function(name)
    return area.zone(root .. "/tests/conformance/elisp/cases/" .. name) == zone
  end,
})
if info.fatal then
  io.write("\n" .. info.fatal .. "\n")
  os.exit(1)
end
if ok then
  io.write("\nzone calls " .. table.concat(vim.tbl_keys(area.trace().calls), " "))
  io.write(string.format("\nzone ok %d %d\n", info.cases, info.recorded))
  os.exit(0)
end
for _, msg in ipairs(problems) do
  io.write(msg .. "\n")
end
os.exit(1)
