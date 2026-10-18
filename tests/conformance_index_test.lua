-- Coverage gate for the Emacs conformance work.  Every inventory ID that
-- organ must change (tests/conformance/ids.tsv) needs a test: a pending
-- signature in a conformance area, or an index row in index.tsv.  Every
-- signature must name known IDs with a class their ruling allows.

local root = vim.fn.getcwd()
local signatures = dofile(root .. "/tests/conformance/_signatures.lua")

local failures = {}
local function fail(msg)
  failures[#failures + 1] = msg
end

local ids = {}
for line in io.lines(root .. "/tests/conformance/ids.tsv") do
  if line:sub(1, 1) ~= "#" then
    local id, ruling, step, oracle = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if not id then
      fail("ids.tsv: malformed row: " .. line)
    else
      ids[id] = { ruling = ruling, step = step, oracle = oracle }
    end
  end
end

local closed = {}
local index = {}
local index_files = { root .. "/tests/conformance/index.tsv" }
vim.list_extend(index_files, vim.fn.glob(root .. "/tests/conformance/*/index.tsv", false, true))
for _, index_file in ipairs(index_files) do
  for line in io.lines(index_file) do
    local c = line:match("^# closed: (.*)$")
    if c then
      for s in c:gmatch("[^%s,]+") do
        closed[s] = true
      end
    elseif line:sub(1, 1) ~= "#" and line ~= "" then
      local id, test, status = line:match("^([^\t]+)\t([^\t]+)\t(%a+)$")
      if not id then
        fail("index.tsv: malformed row: " .. line)
      elseif not ids[id] then
        fail("index.tsv: unknown id " .. id)
      elseif status ~= "pass" and status ~= "pending" and status ~= "todo" then
        fail("index.tsv: unknown status " .. status .. " for " .. id)
      else
        if index[id] then
          fail("index: " .. id .. " has more than one row")
        end
        index[id] = { test = test, status = status }
        local file = test:match("^(tests/.+%.lua)$")
        if file and vim.fn.filereadable(root .. "/" .. file) ~= 1 then
          fail("index.tsv: " .. id .. " names a missing test " .. file)
        end
      end
    end
  end
end

local function step_closed(step)
  if closed[step] then
    return true
  end
  local phase = step:match("^(%w+)%.") or step
  return closed[phase] == true
end

local transitional = {}
local sig_files = vim.fn.glob(root .. "/tests/conformance/*/signatures*.tsv", false, true)
for _, path in ipairs(sig_files) do
  local ok, rows = pcall(signatures.load, path)
  if not ok then
    fail(tostring(rows))
    rows = {}
  end
  local rel = path:sub(#root + 2)
  for _, r in ipairs(rows) do
    local set = {}
    for id in r.id:gmatch("[^,]+") do
      set[#set + 1] = id
    end
    local open_part = false
    for _, member in ipairs(set) do
      -- `~ID` names an entry that contributes only its kept part to the hunk.
      local kept_only = member:sub(1, 1) == "~"
      local id = kept_only and member:sub(2) or member
      local entry = ids[id]
      if kept_only then
        if not entry then
          fail(string.format("%s:%d names unknown id %s", rel, r.line, id))
        elseif not entry.ruling:find("KEEP", 1, true) then
          fail(
            string.format(
              "%s:%d marks %s kept-only but its ruling is %s",
              rel,
              r.line,
              id,
              entry.ruling
            )
          )
        end
      elseif not entry then
        fail(string.format("%s:%d names unknown id %s", rel, r.line, id))
      elseif r.class == "KEEP" and not entry.ruling:find("KEEP", 1, true) then
        fail(
          string.format(
            "%s:%d holds %s as KEEP but its ruling is %s",
            rel,
            r.line,
            id,
            entry.ruling
          )
        )
      elseif
        (r.class == "TARGET" or r.class == "INHERENT")
        and (entry.oracle == "emacs" or entry.oracle == "org-source")
      then
        fail(
          string.format(
            "%s:%d holds %s as %s but its oracle is %s",
            rel,
            r.line,
            id,
            r.class,
            entry.oracle
          )
        )
      elseif
        r.class == "TRANSITIONAL"
        and (entry.ruling:find("FIX", 1, true) or entry.ruling:find("OPT", 1, true))
      then
        -- A pending hunk may also carry a kept difference of another ID;
        -- only the IDs with an outstanding fix or option are pending.
        open_part = true
        transitional[id] = true
        if step_closed(entry.step) then
          fail(
            string.format(
              "%s:%d: %s is still pending but step %s is closed",
              rel,
              r.line,
              id,
              entry.step
            )
          )
        end
      end
    end
    if r.class == "TRANSITIONAL" and not open_part then
      fail(
        string.format(
          "%s:%d is TRANSITIONAL but names no ID with a fix or option part",
          rel,
          r.line
        )
      )
    end
  end
end

local needs_test = {
  FIX = true,
  ["FIX+OPT"] = true,
  ["FIX-INHERENT"] = true,
  ["KEEP+FIX"] = true,
  ["KEEP+OPT"] = true,
}
for id, entry in pairs(ids) do
  if needs_test[entry.ruling] then
    local row = index[id]
    if transitional[id] then
      if row and row.status == "pass" then
        fail(id .. " is marked pass but still holds a TRANSITIONAL signature")
      end
    elseif not row then
      fail(
        id
          .. " ("
          .. entry.ruling
          .. ", step "
          .. entry.step
          .. ") has no test or pending signature"
      )
    elseif row.status == "pending" then
      fail(id .. " is marked pending but holds no TRANSITIONAL signature")
    elseif row.status == "todo" and step_closed(entry.step) then
      fail(id .. " has no test and its step " .. entry.step .. " is closed")
    end
  end
end

if #failures > 0 then
  table.sort(failures)
  io.write(string.format("conformance index: FAIL (%d problem(s))\n", #failures))
  for _, f in ipairs(failures) do
    io.write("  " .. f .. "\n")
  end
  os.exit(1)
end
io.write("conformance index ok\n")
