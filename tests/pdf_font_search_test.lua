-- Font auto-detection tests.
-- Run via: nvim --headless -l tests/pdf_font_search_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local font_search = require("organ.pdf.font_search")

local fails = 0
local checks = 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- 1. Explicit path override -- existing fixture round-trips verbatim.

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local fixture = tmpdir .. "/fake.ttf"
do
  local fh = assert(io.open(fixture, "wb"))
  fh:write("\x00\x01\x00\x00") -- TTF magic; content doesn't matter for this test
  fh:close()
end

local p, err = font_search.find({ path = fixture })
check(
  "explicit path returns the file verbatim",
  p == fixture and err == nil,
  ("got=%s err=%s"):format(tostring(p), tostring(err))
)

-- 2. Explicit path that doesn't exist -- returns (nil, err).

local missing = tmpdir .. "/does-not-exist-" .. tostring(math.random(1, 1e9)) .. ".ttf"
local p2, err2 = font_search.find({ path = missing })
check("missing explicit path returns nil", p2 == nil)
check(
  "missing explicit path error message names the path",
  type(err2) == "string" and err2:find(missing, 1, true) ~= nil,
  ("got %q"):format(tostring(err2))
)

-- 3. fc-match path (only when actually installed; otherwise skip).

if vim.fn.executable("fc-match") == 1 then
  local p3, err3 = font_search.find({ style = "regular" })
  check(
    "fc-match strategy returns an existing file",
    type(p3) == "string" and vim.uv.fs_stat(p3) ~= nil,
    ("got=%s err=%s"):format(tostring(p3), tostring(err3))
  )
else
  print("SKIP  fc-match unavailable (covered by directory walk below)")
end

-- 4. Directory walk -- with fc-match shadowed via the executable() stub.

local orig_executable = vim.fn.executable
vim.fn.executable = function(name)
  if name == "fc-match" then
    return 0
  end
  return orig_executable(name)
end

local p4, err4 = font_search.find({ style = "regular" })

-- Determine whether any of the OS font dirs is populated; if none
-- are, we expect (nil, err) -- otherwise we expect a hit.
local dirs = font_search._os_font_dirs()
local has_any = false
for _, d in ipairs(dirs) do
  if vim.fn.isdirectory(d) == 1 and #vim.fn.glob(d .. "/**/*.ttf", true, true) > 0 then
    has_any = true
    break
  end
end

if has_any then
  check(
    "dir walk returns a *.ttf when fonts are installed",
    type(p4) == "string" and p4:lower():sub(-4) == ".ttf" and vim.uv.fs_stat(p4) ~= nil,
    ("got=%s err=%s"):format(tostring(p4), tostring(err4))
  )
else
  check("dir walk returns nil when no fonts installed", p4 == nil)
  check(
    "dir walk error mentions 'no font found'",
    type(err4) == "string" and err4:find("no font found", 1, true) ~= nil,
    ("got %q"):format(tostring(err4))
  )
end

-- 5. Diagnostic lists at least one directory it tried. We force the
-- no-hit case by also stubbing scandir indirectly: temporarily bait
-- _os_font_dirs with a path that is guaranteed not to exist.

do
  local sentinel_dir = tmpdir .. "/no-such-fonts-dir"
  local saved = font_search._os_font_dirs
  font_search._os_font_dirs = function()
    return { sentinel_dir }
  end
  -- Recompute strategy 3 by re-calling find(); explicit + fc-match
  -- both no-op (fc-match is still stubbed off above).
  local _, err5 = font_search.find({ style = "regular" })
  font_search._os_font_dirs = saved

  check(
    "no-font diagnostic lists the directory that was tried",
    type(err5) == "string" and err5:find(sentinel_dir, 1, true) ~= nil,
    ("got %q"):format(tostring(err5))
  )
end

-- 6. mono style -- when DejaVuSansMono is installed it should win
-- over DejaVuSans.ttf via the preferred-name ranking.

local dejavu_mono = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
if vim.uv.fs_stat(dejavu_mono) then
  local pm, errm = font_search.find({ style = "mono" })
  check(
    "mono style picks DejaVuSansMono.ttf when present",
    pm == dejavu_mono,
    ("got=%s err=%s"):format(tostring(pm), tostring(errm))
  )
else
  print("SKIP  DejaVuSansMono not on this system")
end

-- 7. Bold style -- DejaVuSans-Bold ranks above the regular face when
-- both are present.

local dejavu_bold = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
if vim.uv.fs_stat(dejavu_bold) then
  local pb, errb = font_search.find({ style = "bold" })
  check(
    "bold style picks DejaVuSans-Bold.ttf when present",
    pb == dejavu_bold,
    ("got=%s err=%s"):format(tostring(pb), tostring(errb))
  )
else
  print("SKIP  DejaVuSans-Bold not on this system")
end

-- 8. Regular style -- DejaVuSans.ttf wins when present.

local dejavu_regular = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
if vim.uv.fs_stat(dejavu_regular) then
  local pr, errr = font_search.find({ style = "regular" })
  check(
    "regular style picks DejaVuSans.ttf when present",
    pr == dejavu_regular,
    ("got=%s err=%s"):format(tostring(pr), tostring(errr))
  )
else
  print("SKIP  DejaVuSans.ttf not on this system")
end

-- Restore the executable stub.
vim.fn.executable = orig_executable

-- 9. Unknown style is rejected.

local pu, erru = font_search.find({ style = "wibble" })
check(
  "unknown style returns nil + err",
  pu == nil and type(erru) == "string" and erru:find("unknown style", 1, true) ~= nil
)

-- 10. Explicit path bypasses other strategies -- a non-canonical
-- fixture (not a real font) is returned even though dejavu is on
-- disk. We pass the temp fixture and verify the result is that exact
-- path.

local p_bypass, err_bypass = font_search.find({ path = fixture, style = "bold" })
check(
  "explicit path bypasses fc-match and dir walk",
  p_bypass == fixture and err_bypass == nil,
  ("got=%s err=%s"):format(tostring(p_bypass), tostring(err_bypass))
)

-- 11. fc-match answering with a non-TrueType file (a .ttc collection)
-- is rejected so the directory walk can find an embeddable face.

do
  local ttc = tmpdir .. "/Collection.ttc"
  local fh = assert(io.open(ttc, "wb"))
  fh:write("ttcf\x00\x02\x00\x00")
  fh:close()
  local walk_dir = tmpdir .. "/walk"
  vim.fn.mkdir(walk_dir, "p")
  local walk_ttf = walk_dir .. "/Plain.ttf"
  fh = assert(io.open(walk_ttf, "wb"))
  fh:write("\x00\x01\x00\x00")
  fh:close()

  local saved_exec, saved_system, saved_dirs =
    vim.fn.executable, vim.system, font_search._os_font_dirs
  vim.fn.executable = function(name)
    if name == "fc-match" then
      return 1
    end
    return saved_exec(name)
  end
  vim.system = function(cmd)
    assert(cmd[1] == "fc-match")
    return {
      wait = function()
        return { code = 0, stdout = ttc .. "\n" }
      end,
    }
  end
  font_search._os_font_dirs = function()
    return { walk_dir }
  end
  local p11, err11 = font_search.find({ style = "regular" })
  vim.fn.executable, vim.system, font_search._os_font_dirs = saved_exec, saved_system, saved_dirs
  check(
    "fc-match .ttc answer is skipped in favour of the directory walk",
    p11 == walk_ttf,
    ("got=%s err=%s"):format(tostring(p11), tostring(err11))
  )
end

-- Cleanup.
pcall(vim.fn.delete, fixture)
pcall(vim.fn.delete, tmpdir, "rf")

print(("\n%d check(s), %d failure(s)"):format(checks, fails))
if fails > 0 then
  os.exit(1)
end
print("pdf_font_search_test: OK")
