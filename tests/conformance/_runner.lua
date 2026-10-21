-- Emacs conformance gate: renders an area's corpus through organ and
-- through Emacs, diffs the two per case, and passes only when every
-- difference is recorded in the area's signatures (see _signatures.lua).
--
-- An area is a directory tests/conformance/<area>/ holding:
--
--   cases/           the corpus; every file is listed in manifest.tsv
--   manifest.tsv     cases/<file> <TAB> sha256 of its contents
--   index.tsv        coverage rows for this area (see conformance_index_test)
--   emacs.el         defines (conformance-run LISTFILE OUTDIR OPTION):
--                    for each case path in LISTFILE, writes
--                    OUTDIR/<case basename>.out; OPTION is nil or the
--                    name of an option run
--   organ.lua        returns { render = function(path, option) -> string }
--   normalize.lua    optional: returns function(text, side, case) -> text,
--                    side being "emacs" or "organ"
--   options.lua      optional: returns a list of option-run names
--   signatures.tsv   expected differences of the default run
--   signatures-<option>.tsv   expected differences of each option run
--
-- Both sides run with TZ=UTC and LC_ALL=C.  An organ error while
-- rendering becomes the output "ORGAN-ERROR: <message>", so a crash is a
-- difference like any other and needs a signature to pass.

local M = {}

local root = vim.fn.getcwd()
local signatures = dofile(root .. "/tests/conformance/_signatures.lua")

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function lines_of(text)
  local t = vim.split(text, "\n", { plain = true })
  if t[#t] == "" then
    t[#t] = nil
  end
  return t
end

--- Hunks of a line diff between two texts, as signature hunk strings.
function M.hunks(a_text, b_text)
  local a, b = lines_of(a_text), lines_of(b_text)
  local out = {}
  local ta, tb = table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n"
  for _, h in ipairs(vim.diff(ta, tb, { result_type = "indices" })) do
    local parts = {}
    for i = h[1], h[1] + h[2] - 1 do
      parts[#parts + 1] = "-" .. a[i]
    end
    for i = h[3], h[3] + h[4] - 1 do
      parts[#parts + 1] = "+" .. b[i]
    end
    out[#out + 1] = table.concat(parts, "\n")
  end
  return out
end

--- Manifest rows for `area`: list of { path = "cases/<f>", sha = "..." }.
function M.manifest(area)
  local rows = {}
  local text = read(root .. "/tests/conformance/" .. area .. "/manifest.tsv") or ""
  for line in text:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
      local path, sha = line:match("^([^\t]+)\t(%x+)$")
      if path then
        rows[#rows + 1] = { path = path, sha = sha }
      end
    end
  end
  return rows
end

local function check_manifest(area, problems)
  local dir = root .. "/tests/conformance/" .. area .. "/cases"
  local listed = {}
  local cases = {}
  for _, row in ipairs(M.manifest(area)) do
    listed[row.path] = true
    local full = root .. "/tests/conformance/" .. area .. "/" .. row.path
    local content = read(full)
    if not content then
      problems[#problems + 1] = "manifest lists a missing case: " .. row.path
    elseif vim.fn.sha256(content) ~= row.sha then
      problems[#problems + 1] = "case changed without a manifest update: " .. row.path
    else
      cases[#cases + 1] = full
    end
  end
  for _, f in ipairs(vim.fn.globpath(dir, "*", false, true)) do
    local rel = "cases/" .. vim.fn.fnamemodify(f, ":t")
    if not listed[rel] then
      problems[#problems + 1] = "case not in manifest: " .. rel
    end
  end
  table.sort(cases)
  return cases
end

local function run_emacs(area, cases, option, problems)
  local dir = root .. "/tests/conformance/" .. area
  local out_dir = vim.fn.tempname()
  vim.fn.mkdir(out_dir, "p")
  local list = out_dir .. "/cases.txt"
  vim.fn.writefile(cases, list)
  local form = string.format(
    "(conformance-run %q %q %s)",
    list,
    out_dir,
    option and string.format("%q", option) or "nil"
  )
  local cmd = {
    "env",
    "TZ=UTC",
    "LC_ALL=C",
    "timeout",
    "-k",
    "5",
    "900",
    "emacs",
    "--batch",
    "-Q",
    "-l",
    dir .. "/emacs.el",
    "--eval",
    form,
  }
  local log = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    problems[#problems + 1] =
      string.format("emacs side failed (exit %d): %s", vim.v.shell_error, log:sub(1, 2000))
    return nil
  end
  local outputs = {}
  for _, case in ipairs(cases) do
    local text = read(out_dir .. "/" .. vim.fn.fnamemodify(case, ":t") .. ".out")
    if not text then
      problems[#problems + 1] = "emacs side wrote no output for " .. vim.fn.fnamemodify(case, ":t")
    end
    outputs[case] = text
  end
  vim.fn.delete(out_dir, "rf")
  return outputs
end

local function run_one(area, cases, option)
  local dir = root .. "/tests/conformance/" .. area
  local problems = {}
  local organ = dofile(dir .. "/organ.lua")
  local normalize_path = dir .. "/normalize.lua"
  local normalize = vim.fn.filereadable(normalize_path) == 1 and dofile(normalize_path)
    or function(text)
      return text
    end
  local emacs_out = run_emacs(area, cases, option, problems)
  if not emacs_out then
    return problems, 0
  end
  local observed = {}
  for _, case in ipairs(cases) do
    local name = vim.fn.fnamemodify(case, ":t")
    local ok, organ_text = pcall(organ.render, case, option)
    if not ok then
      organ_text = "ORGAN-ERROR: " .. tostring(organ_text):gsub("\n", " ") .. "\n"
    end
    local e = normalize(emacs_out[case] or "", "emacs", name)
    local o = normalize(organ_text or "", "organ", name)
    local hunks = M.hunks(e, o)
    if #hunks > 0 then
      observed[name] = hunks
    end
  end
  local sig_file = dir .. (option and ("/signatures-" .. option .. ".tsv") or "/signatures.tsv")
  local rows = {}
  if vim.fn.filereadable(sig_file) == 1 then
    local ok, loaded = pcall(signatures.load, sig_file)
    if not ok then
      problems[#problems + 1] = tostring(loaded)
      return problems, 0
    end
    rows = loaded
  end
  vim.list_extend(problems, signatures.check(observed, rows))
  return problems, #rows
end

--- Run the gate for `area` and exit the process with its result.
function M.main(area)
  vim.env.ORGAN_TEST_DB = vim.fn.tempname() .. "-" .. area .. ".db"
  dofile(root .. "/tests/_bootstrap.lua")
  if vim.fn.executable("emacs") ~= 1 then
    if vim.env.CI and vim.env.CI ~= "" then
      io.write("conformance " .. area .. ": FAIL (emacs not installed, and CI must run the gate)\n")
      os.exit(1)
    end
    io.write("conformance " .. area .. ": SKIP (emacs not installed)\n")
    os.exit(0)
  end
  if os.getenv("TZ") ~= "UTC" or os.getenv("LC_ALL") ~= "C" then
    io.write(
      "conformance " .. area .. ": FAIL (run with TZ=UTC LC_ALL=C, as `make conformance` does)\n"
    )
    os.exit(1)
  end
  local problems = {}
  local cases = check_manifest(area, problems)
  if #cases == 0 then
    problems[#problems + 1] = "no cases"
  end
  local runs = { false }
  local options_path = root .. "/tests/conformance/" .. area .. "/options.lua"
  if vim.fn.filereadable(options_path) == 1 then
    vim.list_extend(runs, dofile(options_path))
  end
  local recorded = 0
  if #problems == 0 then
    for _, option in ipairs(runs) do
      local p, n = run_one(area, cases, option or nil)
      recorded = recorded + n
      for _, msg in ipairs(p) do
        problems[#problems + 1] = (option and ("[" .. option .. "] ") or "") .. msg
      end
    end
  end
  if #problems == 0 then
    io.write(
      string.format(
        "conformance %s ok (%d cases, %d run(s), %d expected difference(s))\n",
        area,
        #cases,
        #runs,
        recorded
      )
    )
    os.exit(0)
  end
  io.write(string.format("conformance %s: FAIL (%d problem(s))\n", area, #problems))
  for _, msg in ipairs(problems) do
    io.write("  " .. msg .. "\n")
  end
  os.exit(1)
end

return M
