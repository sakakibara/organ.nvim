-- Static keymap audit — scans every place organ.nvim registers a
-- buffer-local keymap and asserts none of them shadow vim normal-mode
-- keys that users have hard-wired muscle memory for, AND none of them
-- start with a key that would create a timeoutlen wait on a bare
-- single-char vim binding.
--
-- The latter category caught the `vd`/`vw` bug: pressing `v` in agenda
-- to enter visual mode triggered a 1-second wait while vim disambiguated
-- between bare `v` and the `v[d|w]` view bindings.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Keys that are universal vim normal-mode operations — binding any of
-- these as a single-char keymap shadows them. Allowed in NOMODIFIABLE
-- buffers only when (a) we explicitly accept the conflict and (b) the
-- key has no useful function in nomodifiable.
local FORBIDDEN_BARE = {
  ["v"] = "visual-character mode",
  ["V"] = "visual-line mode",
  ["o"] = "open new line below (insert)", -- often allowed in nomodifiable, but breaks muscle memory
}

-- Keys that are common vim PREFIXES — any registered keymap that starts
-- with these will trigger timeoutlen waits when the user just presses
-- the prefix. Not strictly forbidden, but worth flagging.
local TIMEOUT_PREFIXES = { "v", "V", "g", "z", "[", "]", "<C-w>" }

-- Files to scan — every place organ registers a buffer-local keymap
-- inside an organ-controlled buffer (agenda, backlinks, picker popups,
-- etc.). We do NOT scan ftplugin/* since those are user-org-buffer
-- keymaps and operate under different conventions (LocalLeader-based,
-- explicit user opt-in).
local FILES_TO_SCAN = {
  "lua/organ/agenda.lua",
  "lua/organ/backlinks.lua",
  "lua/organ/column_view.lua",
  "lua/organ/roam/sidebar.lua",
  "lua/organ/roam/graph.lua",
  "lua/organ/latex_preview.lua",
  "lua/organ/calendar.lua",
}

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Extract every keymap LHS literal from a file via static scan. Two
-- patterns to match:
--   1. nvim_buf_set_keymap(bufnr, "n", "LHS", ...)
--   2. map("LHS", ...)
local function lhs_in_file(path)
  local lhs_set = {}
  local fh = io.open(path, "r")
  if not fh then
    return lhs_set
  end
  local body = fh:read("*a")
  fh:close()
  -- Skip comment lines (start with --)
  for line in body:gmatch("[^\n]+") do
    -- skip lines that look like comments at start
    if not line:match("^%s*%-%-") then
      -- Pattern 1: nvim_buf_set_keymap(_, _, "LHS", ...)
      for lhs in line:gmatch('nvim_buf_set_keymap%([^,]+,[^,]+,%s*"([^"]+)"') do
        lhs_set[lhs] = true
      end
      -- Pattern 2: map("LHS", ...) — typical inner helper in agenda/backlinks
      -- Only match when the line looks like a top-level map() call (not part
      -- of a string or name like "map_foo")
      for lhs in line:gmatch('[^A-Za-z_]map%(%s*"([^"]+)"') do
        lhs_set[lhs] = true
      end
      -- Also match leading map( at start of line (after leading whitespace)
      for lhs in line:gmatch('^%s*map%(%s*"([^"]+)"') do
        lhs_set[lhs] = true
      end
    end
  end
  return lhs_set
end

for _, path in ipairs(FILES_TO_SCAN) do
  local lhs_set = lhs_in_file(path)
  local lhs_list = {}
  for k in pairs(lhs_set) do
    lhs_list[#lhs_list + 1] = k
  end
  table.sort(lhs_list)

  -- Check 1: no bare-forbidden bindings
  for k, why in pairs(FORBIDDEN_BARE) do
    check(
      string.format("%s does not bind bare `%s` (would shadow %s)", path:match("[^/]+$"), k, why),
      not lhs_set[k]
    )
  end

  -- Check 2: any binding starting with a timeoutlen prefix means there
  -- is also a bare-prefix binding OR the user accepts the wait. Detect
  -- and warn for `v[x]` since that's our specific bug surface.
  for _, lhs in ipairs(lhs_list) do
    if #lhs >= 2 and lhs:sub(1, 1) == "v" and lhs:sub(2, 2):match("[%w]") then
      -- A binding like "vd" / "vw" creates a 1-sec wait on bare `v`.
      check(
        string.format(
          "%s does not bind a `v[char]` sequence (causes visual-mode wait): %s",
          path:match("[^/]+$"),
          lhs
        ),
        false,
        "found: " .. lhs
      )
    end
  end
end

-- ---------------------------------------------------------------------------
-- ALSO audit the resolved defaults: in-code literals can be overridden by
-- `lua/organ/defaults.lua` (via the `cfg[desc]` path in agenda.lua's
-- map helper, etc.). A bad default re-introduces the shadow even when
-- the literal in the .lua file was correct.
-- ---------------------------------------------------------------------------
local defaults = dofile("lua/organ/defaults.lua")

local function audit_keymap_table(name, t)
  if type(t) ~= "table" then
    return
  end
  for desc, lhs in pairs(t) do
    if type(lhs) == "string" then
      for k, why in pairs(FORBIDDEN_BARE) do
        check(
          string.format("defaults.%s.%s ≠ bare `%s` (would shadow %s)", name, desc, k, why),
          lhs ~= k
        )
      end
      if #lhs >= 2 and lhs:sub(1, 1) == "v" and lhs:sub(2, 2):match("[%w]") then
        check(
          string.format(
            "defaults.%s.%s does not start with `v[char]` (causes visual-mode wait)",
            name,
            desc
          ),
          false,
          "found: " .. lhs
        )
      end
    end
  end
end

audit_keymap_table("agenda.keymaps", (defaults.agenda or {}).keymaps)
audit_keymap_table("backlinks.keymaps", (defaults.backlinks or {}).keymaps)
audit_keymap_table("calendar.keymaps", (defaults.calendar or {}).keymaps)
audit_keymap_table("roam.keymaps", (defaults.roam or {}).keymaps)
audit_keymap_table("find.keymaps", (defaults.find or {}).keymaps)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("keymap_audit_test: PASS")
