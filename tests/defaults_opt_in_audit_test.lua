-- Static audit: every field the codebase treats as "opt-in"
-- (i.e. behaviour fires only when `cfg.X == true`) MUST NOT have
-- `X = true` set in lua/organ/defaults.lua. Otherwise "opt-in" is a no-op
-- because the default IS already true and any user setup that doesn't
-- override gets the behaviour silently.
--
-- This audit hit twice in flight ("you said X is opt-in, but it isn't"):
--   1. `agenda.footer` — code did `cfg.footer == true` while defaults had
--      `footer = true` → footer was always-on.
--   2. `agenda.{winbar,statusline}` — apply() defaulted to "use default"
--      when the user passed nil → buffer chrome was silently overwritten.
--
-- Add an entry below for any new opt-in field. The test reads
-- defaults.lua and asserts the field is either absent or NOT `true`.
--
-- Run via: nvim --headless -l tests/defaults_opt_in_audit_test.lua

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Each entry: { dotted-path, "rationale (where the opt-in semantics are checked)" }
local OPT_IN_FIELDS = {
  -- Window chrome — must NEVER be silently set on the user's behalf.
  -- Code path: organ.statusline.apply only acts on `true / string / function`.
  { "agenda.winbar", "organ/statusline.lua: should_apply()" },
  { "agenda.statusline", "organ/statusline.lua: should_apply()" },
  { "backlinks.winbar", "organ/statusline.lua: should_apply()" },
  { "backlinks.statusline", "organ/statusline.lua: should_apply()" },

  -- alarms.local_schedule routes reminders through the OS scheduler. Must
  -- be explicit opt-in (writes plists / installs LaunchAgents).
  { "alarms.local_schedule", "organ/alarms.lua: cfg().local_schedule" },

  -- Babel run: gate on confirm_evaluate via vim.fn.confirm. Allow_languages
  -- is opt-in (skip prompt for that language). Must be empty by default.
  -- (allow_languages is a list, not a bool — checked separately below.)
}

local defaults = dofile("lua/organ/defaults.lua")

local function get(tree, path)
  local cur = tree
  for part in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[part]
  end
  return cur
end

for _, entry in ipairs(OPT_IN_FIELDS) do
  local path, why = entry[1], entry[2]
  local v = get(defaults, path)
  check(
    ("opt-in: defaults.%s is not `true` (%s)"):format(path, why),
    v ~= true,
    "got " .. vim.inspect(v)
  )
end

-- List-typed opt-ins: defaults must be empty (any non-empty list bypasses
-- the gate for those entries).
do
  local allow = get(defaults, "babel.allow_languages")
  check(
    "opt-in (list): defaults.babel.allow_languages is empty",
    type(allow) == "table" and #allow == 0,
    "got " .. vim.inspect(allow)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  print()
  print("If a field NEEDS to default to true (i.e. is NOT opt-in), remove it")
  print("from OPT_IN_FIELDS. If it should stay opt-in, change defaults.lua")
  print("to either omit it or set it false.")
  os.exit(1)
end
print()
print("defaults_opt_in_audit_test: PASS")
