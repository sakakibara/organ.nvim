-- organ.statusline: composable elements + lualine factory + apply()
-- safety (buffer-local only, never touches global vim.o.winbar/statusline).
--
-- Run via: nvim --headless -l tests/statusline_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local sl = require("organ.statusline")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- 1. Element accessors return "" / "0" for non-organ buffers — the cond
--    gates in lualine components rely on these being safe.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  check("non-organ: view_name returns ''", sl.view_name() == "")
  check("non-organ: entry_count returns '0'", sl.entry_count() == "0")
  check("non-organ: date_range returns ''", sl.date_range() == "")
  check("non-organ: active_filter returns ''", sl.active_filter() == "")
  check("non-organ: buffer_kind returns ''", sl.buffer_kind() == "")
end

-- ---------------------------------------------------------------------------
-- 2. With organ-agenda state \(buffer-local\), accessors return live values.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.b[b].organ_agenda = {
    view_name = "today",
    window = { from = "2026-05-03", to = "2026-05-09" },
    line_index = { [1] = nil, [2] = { id = "h1" }, [3] = { id = "h2" }, [4] = { id = "h3" } },
    title_filter = "tag:work",
  }
  check("agenda: view_name returns 'today'", sl.view_name() == "today")
  check("agenda: entry_count returns '3'", sl.entry_count() == "3", "got " .. sl.entry_count())
  check(
    "agenda: date_range carries `→`",
    sl.date_range():find("→", 1, true) ~= nil,
    "got " .. sl.date_range()
  )
  check("agenda: active_filter passes through", sl.active_filter() == "tag:work")
  check("agenda: buffer_kind returns 'Agenda'", sl.buffer_kind() == "Agenda")
end

-- ---------------------------------------------------------------------------
-- 3. Default composers produce well-formed strings.
-- ---------------------------------------------------------------------------
do
  local s = sl.agenda_winbar()
  check(
    "agenda_winbar: contains '[Agenda: today]'",
    s:find("[Agenda: today]", 1, true) ~= nil,
    "got " .. s
  )
  check("agenda_winbar: contains entry count", s:find("3 entries", 1, true) ~= nil)
  check("agenda_winbar: contains filter", s:find("tag:work", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
-- 4. lualine components: each returns a table with [1]=function + cond.
--    Components don't render in non-organ buffers (cond returns false).
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true) -- no organ state
  vim.api.nvim_set_current_buf(b)

  local kind = sl.lualine.kind()
  check(
    "lualine.kind: returns table with [1] function",
    type(kind) == "table" and type(kind[1]) == "function"
  )
  check("lualine.kind: cond is a function", type(kind.cond) == "function")
  check("lualine.kind: cond is false in non-organ buffer", kind.cond() == false)

  local entries = sl.lualine.entries()
  check("lualine.entries: cond is false in non-organ buffer", entries.cond() == false)
end

do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.b[b].organ_agenda = {
    view_name = "todos",
    line_index = { [1] = { id = "x" }, [2] = { id = "y" } },
  }
  local kind = sl.lualine.kind()
  local entries = sl.lualine.entries()
  check("lualine.kind: cond true in agenda buffer", kind.cond() == true)
  check(
    "lualine.kind: value = '[Agenda: todos]'",
    kind[1]() == "[Agenda: todos]",
    "got " .. tostring(kind[1]())
  )
  check(
    "lualine.entries: value = '2 entries'",
    entries[1]() == "2 entries",
    "got " .. tostring(entries[1]())
  )

  -- User-supplied opts are merged in (allows icon, color, etc.).
  local with_icon = sl.lualine.kind({ icon = "" })
  check("lualine.kind(opts): merges user opts", with_icon.icon == "")
end

-- ---------------------------------------------------------------------------
-- 5. resolve(): false → nil, true/nil → default expr, string → literal,
--    function → invoked with bufnr.
-- ---------------------------------------------------------------------------
do
  local r1 = sl.resolve(false, "agenda_winbar", 1)
  check("resolve(false): returns nil (disabled)", r1 == nil)

  local r2 = sl.resolve(nil, "agenda_winbar", 7)
  check(
    "resolve(nil): returns default %!v:lua expr",
    type(r2) == "string"
      and r2:find("%!v:lua", 1, true) == 1
      and r2:find("agenda_winbar(7)", 1, true) ~= nil,
    "got " .. tostring(r2)
  )

  local r3 = sl.resolve("custom %f", "agenda_winbar", 0)
  check("resolve(string): returns literal", r3 == "custom %f")

  local r4 = sl.resolve(function(_)
    return "user-fn"
  end, "agenda_winbar", 0)
  check("resolve(function): returns invoked value", r4 == "user-fn")

  -- Throwing function: warned, returns nil + err string.
  local r5, err = sl.resolve(function(_)
    error("oops")
  end, "agenda_winbar", 0)
  check(
    "resolve(throwing fn): returns nil + error string",
    r5 == nil and type(err) == "string" and err:find("errored")
  )
end

-- ---------------------------------------------------------------------------
-- 6. apply(): never touches the global vim.o.{winbar,statusline}.
--    The sole side-effect should be on the WINDOW-local options.
-- ---------------------------------------------------------------------------
do
  -- Use scope=global to check the GLOBAL value (vim.o.* falls back to
  -- window-local when global is unset, masking whether we leaked).
  local function global_opt(name)
    return vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  local saved_global_winbar = global_opt("winbar")
  local saved_global_statusline = global_opt("statusline")

  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.b[b].organ_agenda = { view_name = "today", line_index = {} }

  -- No-surprises rule: nil = leave alone. Sentinel pre-set so we can
  -- detect whether apply() touched it.
  local winid = vim.fn.bufwinid(b)
  if winid ~= -1 then
    vim.api.nvim_set_option_value("winbar", "PRE-SENTINEL", { scope = "local", win = winid })
    vim.api.nvim_set_option_value("statusline", "PRE-SENTINEL", { scope = "local", win = winid })
  end

  sl.apply(b, {
    winbar = nil, -- nil = no-op (don't surprise the user)
    winbar_default = "agenda_winbar",
    statusline = nil,
    statusline_default = "agenda_statusline",
  })

  check(
    "apply: GLOBAL winbar untouched",
    global_opt("winbar") == saved_global_winbar,
    "global winbar mutated to: " .. global_opt("winbar")
  )
  check(
    "apply: GLOBAL statusline untouched",
    global_opt("statusline") == saved_global_statusline,
    "global statusline mutated to: " .. global_opt("statusline")
  )

  if winid ~= -1 then
    check(
      "apply(nil): window winbar UNCHANGED (no-surprise rule)",
      vim.wo[winid].winbar == "PRE-SENTINEL",
      "got: " .. vim.wo[winid].winbar
    )
    check(
      "apply(nil): window statusline UNCHANGED (no-surprise rule)",
      vim.wo[winid].statusline == "PRE-SENTINEL",
      "got: " .. vim.wo[winid].statusline
    )
  end

  -- Now flip to true → DOES install the default.
  sl.apply(b, {
    winbar = true,
    winbar_default = "agenda_winbar",
    statusline = true,
    statusline_default = "agenda_statusline",
  })
  if winid ~= -1 then
    check(
      "apply(true): window-local winbar is set to default expr",
      vim.wo[winid].winbar:find("agenda_winbar") ~= nil,
      "got: " .. vim.wo[winid].winbar
    )
    check(
      "apply(true): window-local statusline is set to default expr",
      vim.wo[winid].statusline:find("agenda_statusline") ~= nil,
      "got: " .. vim.wo[winid].statusline
    )
  end
end

-- ---------------------------------------------------------------------------
-- 7. apply with winbar=false: WINDOW-local winbar should NOT be mutated.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  local winid = vim.api.nvim_get_current_win()
  -- Set a sentinel value the user might have configured.
  vim.wo[winid].winbar = "USER-CUSTOM"

  sl.apply(b, {
    winbar = false, -- explicitly disabled
    winbar_default = "agenda_winbar",
    statusline = false,
    statusline_default = "agenda_statusline",
  })

  check(
    "apply(winbar=false): window winbar unchanged (USER-CUSTOM)",
    vim.wo[winid].winbar == "USER-CUSTOM",
    "got: " .. vim.wo[winid].winbar
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("statusline_test: PASS")
