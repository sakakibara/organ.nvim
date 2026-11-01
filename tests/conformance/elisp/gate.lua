-- elisp gate: the corpus (tests/conformance/_runner.lua), then the check
-- of the Emacs data organ.elisp carries: scripts/elisp-data.el must
-- regenerate lua/organ/elisp/data/ byte for byte, and organ's lookups
-- must agree with Emacs's per-code-point dump.  Then every builtin of
-- the subset must be called by some case, and the fuzz (fuzz.lua) must
-- find no disagreement.
--
-- Cases whose header names a `tz` run in a separate pair of processes
-- per zone (zone.lua, started with that TZ), as the C library reads TZ
-- once per process; the rest run here under TZ=UTC.

local root = vim.fn.getcwd()
local runner = dofile(root .. "/tests/conformance/_runner.lua")
local area = dofile(root .. "/tests/conformance/elisp/organ.lua")
local CASES = root .. "/tests/conformance/elisp/cases/"

local ok, problems, info = runner.run("elisp", {
  select = function(name)
    return area.zone(CASES .. name) == nil
  end,
})
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
local chars = require("organ.elisp.chars")
local V = require("organ.elisp.value")

local CASE_KINDS = { "upcase", "downcase", "capitalize" }

local function codes_of(s)
  local out, i = {}, 1
  while i <= #s do
    local cp, j = V.utf8_next(s, i)
    out[#out + 1] = string.format("%X", cp)
    i = j
  end
  return table.concat(out, ",")
end

-- organ's lookups over Emacs's per-character dump (elisp-data-dump-chars):
-- the number of characters checked; differences go to `problems'.
local function check_chars(path)
  local bad, n, next_c = 0, 0, 0
  local function differ(c, what, got, want)
    bad = bad + 1
    if bad <= 5 then
      problems[#problems + 1] = string.format(
        "data: %s of U+%04X: organ %s, Emacs %s",
        what,
        c,
        tostring(got),
        tostring(want)
      )
    end
  end
  local function check_maps(c, up, down, title)
    for k, want in ipairs({ up, down, title }) do
      local got = chars.case_char(CASE_KINDS[k], c)
      if got ~= want then
        differ(c, CASE_KINDS[k], got, want)
      end
    end
  end
  local function identity_until(last)
    while next_c <= last do
      check_maps(next_c, next_c, next_c, next_c)
      n = n + 1
      next_c = next_c + 1
    end
  end
  for line in io.lines(path) do
    local f = vim.split(line, " ", { plain = true })
    if f[1] == "end" then
      identity_until(tonumber(f[2]))
    else
      local c = tonumber(f[1])
      if c ~= next_c then
        identity_until(c - 1)
      end
      check_maps(c, tonumber(f[2]), tonumber(f[3]), tonumber(f[4]))
      if #f > 4 then
        if chars.canon(c) ~= tonumber(f[5]) then
          differ(c, "canon", chars.canon(c), f[5])
        end
        if chars.char_width(c) ~= tonumber(f[6]) then
          differ(c, "char-width", chars.char_width(c), f[6])
        end
        if (chars.composes(c) and "1" or "0") ~= f[7] then
          differ(c, "composition", chars.composes(c), f[7])
        end
        if (chars.cjk(c) and "1" or "0") ~= f[8] then
          differ(c, "cjk width", chars.cjk(c), f[8])
        end
        for k, kind in ipairs(CASE_KINDS) do
          local s = chars.case_special(kind, c)
          local got = s and codes_of(s) or "="
          if got ~= f[8 + k] then
            differ(c, kind .. " of its string", got, f[8 + k])
          end
        end
      end
      n = n + 1
      next_c = c + 1
    end
  end
  if bad > 5 then
    problems[#problems + 1] = string.format("data: %d more character differences", bad - 5)
  end
  if next_c ~= 0x400000 then
    problems[#problems + 1] = string.format("data: character dump ends at %X", next_c - 1)
  end
  return n
end

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
  local chars_truth = tmp .. "/chars.txt"
  if emacs_data(string.format("(elisp-data-dump-chars %q)", chars_truth)) then
    points = points + check_chars(chars_truth)
  end
  vim.fn.delete(tmp, "rf")
  return files, points
end

local calls = area.trace().calls

-- Each zone's cases in a child process with TZ set to it: adds the
-- child's counts to `info` and its problems to `problems`.
local function run_zones()
  local zones, seen = {}, {}
  for _, row in ipairs(runner.manifest("elisp")) do
    local z = area.zone(root .. "/tests/conformance/elisp/" .. row.path)
    if z and not seen[z] then
      seen[z] = true
      zones[#zones + 1] = z
    end
  end
  table.sort(zones)
  for _, z in ipairs(zones) do
    local out = vim.fn.system({
      "env",
      "TZ=" .. z,
      "LC_ALL=C",
      "timeout",
      "-k",
      "5",
      "900",
      vim.v.progpath,
      "--headless",
      "-l",
      root .. "/tests/conformance/elisp/zone.lua",
      z,
    })
    local cases, recorded = out:match("\nzone ok (%d+) (%d+)\n")
    if vim.v.shell_error == 0 and cases then
      for name in (out:match("\nzone calls ([^\n]*)") or ""):gmatch("%S+") do
        calls[name] = true
      end
      info.cases = info.cases + tonumber(cases)
      info.recorded = info.recorded + tonumber(recorded)
      info.runs = info.runs + 1
    else
      ok = false
      problems[#problems + 1] = string.format("TZ=%s run failed (exit %d):", z, vim.v.shell_error)
      for line in out:gmatch("[^\n]+") do
        problems[#problems + 1] = "  " .. line
      end
    end
  end
end

run_zones()

local files, points = check_data()

local uncovered = {}
for name in pairs(require("organ.elisp.builtins").SUBSET) do
  if not calls[name] then
    uncovered[#uncovered + 1] = name
  end
end
table.sort(uncovered)
if #uncovered > 0 then
  problems[#problems + 1] = "builtins no case calls: " .. table.concat(uncovered, " ")
end

local fuzz = dofile(root .. "/tests/conformance/elisp/fuzz.lua").run(area, problems)

for line in io.lines(root .. "/tests/conformance/elisp/signatures.tsv") do
  if line:sub(1, 1) ~= "#" and line:find("REFUSED internal", 1, true) then
    problems[#problems + 1] = "signatures.tsv records an internal refusal: " .. line:sub(1, 200)
  end
end

if ok and #problems == 0 then
  io.write(
    string.format(
      "conformance elisp ok (%d cases, %d run(s), %d expected difference(s); "
        .. "data: %d files, %d code points; fuzz: %s)\n",
      info.cases,
      info.runs,
      info.recorded,
      files,
      points,
      fuzz
    )
  )
  os.exit(0)
end
io.write(string.format("conformance elisp: FAIL (%d problem(s))\n", #problems))
for _, msg in ipairs(problems) do
  io.write("  " .. msg .. "\n")
end
os.exit(1)
