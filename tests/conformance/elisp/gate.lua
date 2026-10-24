-- elisp gate: the corpus (tests/conformance/_runner.lua), then the check
-- of the Emacs data organ.elisp carries: scripts/elisp-data.el must
-- regenerate lua/organ/elisp/data/ byte for byte, and organ's lookups
-- must agree with Emacs's per-code-point dump.

local root = vim.fn.getcwd()
local runner = dofile(root .. "/tests/conformance/_runner.lua")

local ok, problems, info = runner.run("elisp")
if info.skip then
  io.write("conformance elisp: SKIP (" .. info.skip .. ")\n")
  os.exit(0)
end
if info.fatal then
  io.write("conformance elisp: FAIL (" .. info.fatal .. ")\n")
  os.exit(1)
end

local DATA_DIR = root .. "/lua/organ/elisp/data"

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function emacs_data(form)
  local log = vim.fn.system({
    "timeout",
    "-k",
    "5",
    "300",
    "emacs",
    "--batch",
    "-Q",
    "-l",
    root .. "/scripts/elisp-data.el",
    "--eval",
    form,
  })
  if vim.v.shell_error ~= 0 then
    problems[#problems + 1] =
      string.format("data: emacs failed (exit %d): %s", vim.v.shell_error, log:sub(1, 2000))
    return false
  end
  return true
end

local syntax = require("organ.elisp.syntax")

local function check_data()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local files, points = 0, 0
  if emacs_data(string.format("(elisp-data-write %q)", tmp)) then
    local names = {}
    for _, f in ipairs(vim.fn.globpath(tmp, "*.lua", false, true)) do
      names[vim.fn.fnamemodify(f, ":t")] = true
    end
    for _, f in ipairs(vim.fn.globpath(DATA_DIR, "*.lua", false, true)) do
      names[vim.fn.fnamemodify(f, ":t")] = true
    end
    local sorted = vim.tbl_keys(names)
    table.sort(sorted)
    for _, name in ipairs(sorted) do
      files = files + 1
      local want, have = read(tmp .. "/" .. name), read(DATA_DIR .. "/" .. name)
      if want ~= have then
        problems[#problems + 1] = string.format(
          "data: lua/organ/elisp/data/%s %s; regenerate with emacs --batch -Q "
            .. "-l scripts/elisp-data.el --eval '(elisp-data-write \"lua/organ/elisp/data\")'",
          name,
          not have and "is missing" or not want and "is not generated" or "differs"
        )
      end
    end
  end
  local truth = tmp .. "/truth.txt"
  if emacs_data(string.format("(elisp-data-dump-truth %q)", truth)) then
    local cp = {}
    local bad = 0
    for line in io.lines(truth) do
      local tbl, code, match = line:match("^(%a+) (%-?%d+) (%-?%d+)$")
      local c = cp[tbl] or 0
      cp[tbl] = c + 1
      points = points + 1
      local got_code, got_match = syntax.lookup(tbl, c)
      if got_code ~= tonumber(code) or got_match ~= tonumber(match) then
        bad = bad + 1
        if bad <= 5 then
          problems[#problems + 1] = string.format(
            "data: %s syntax of U+%04X: organ %s %s, Emacs %s %s",
            tbl,
            c,
            tostring(got_code),
            tostring(got_match),
            code,
            match
          )
        end
      end
    end
    if bad > 5 then
      problems[#problems + 1] = string.format("data: %d more syntax differences", bad - 5)
    end
    for tbl, n in pairs(cp) do
      if n ~= 0x110000 then
        problems[#problems + 1] = string.format("data: %s dump holds %d code points", tbl, n)
      end
    end
  end
  vim.fn.delete(tmp, "rf")
  return files, points
end

local files, points = check_data()

for line in io.lines(root .. "/tests/conformance/elisp/signatures.tsv") do
  if line:sub(1, 1) ~= "#" and line:find("REFUSED internal", 1, true) then
    problems[#problems + 1] = "signatures.tsv records an internal refusal: " .. line:sub(1, 200)
  end
end

if ok and #problems == 0 then
  io.write(
    string.format(
      "conformance elisp ok (%d cases, %d run(s), %d expected difference(s); "
        .. "data: %d files, %d code points)\n",
      info.cases,
      info.runs,
      info.recorded,
      files,
      points
    )
  )
  os.exit(0)
end
io.write(string.format("conformance elisp: FAIL (%d problem(s))\n", #problems))
for _, msg in ipairs(problems) do
  io.write("  " .. msg .. "\n")
end
os.exit(1)
