-- duration gate: the corpus (tests/conformance/_runner.lua), then the
-- fuzz (fuzz.lua), which must find no disagreement.

local root = vim.fn.getcwd()
local runner = dofile(root .. "/tests/conformance/_runner.lua")
local area = dofile(root .. "/tests/conformance/duration/organ.lua")

local ok, problems, info = runner.run("duration")
if info.skip then
  io.write("conformance duration: SKIP (" .. info.skip .. ")\n")
  os.exit(0)
end
if info.fatal then
  io.write("conformance duration: FAIL (" .. info.fatal .. ")\n")
  os.exit(1)
end

local fuzz = dofile(root .. "/tests/conformance/duration/fuzz.lua").run(area, problems)

if ok and #problems == 0 then
  io.write(
    string.format(
      "conformance duration ok (%d cases, %d run(s), %d expected difference(s); fuzz: %s)\n",
      info.cases,
      info.runs,
      info.recorded,
      fuzz
    )
  )
  os.exit(0)
end
io.write(string.format("conformance duration: FAIL (%d problem(s))\n", #problems))
for _, msg in ipairs(problems) do
  io.write("  " .. msg .. "\n")
end
os.exit(1)
