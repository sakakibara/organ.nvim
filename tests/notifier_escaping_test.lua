-- Per-platform notifier-backend escaping tests.
--
-- The bug class: a headline with `<`, `>`, `&`, `"`, `'`, or shell metachar
-- in the title gets fed into a plist (macOS) / `at(1)` stdin (Linux) /
-- PowerShell here-string (Windows). Without correct escaping it either
-- (a) produces malformed XML the launcher rejects, (b) breaks shell
-- argument parsing so the wrong title gets shown, or (c) opens a code
-- injection vector via shell expansion.
--
-- We probe the helpers directly. They are exposed as `M._<name>` on each
-- backend module specifically for this test (and for diagnostics).
--
-- Run via: nvim --headless -l tests/notifier_escaping_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

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
-- macOS: XML escaping + plist payload
-- ---------------------------------------------------------------------------
local mac = require("organ.notifier.macos")

do
  local esc = mac._escape_xml
  check("mac escape: & → &amp;", esc("a & b") == "a &amp; b")
  check("mac escape: <urgent> → &lt;urgent&gt;", esc("<urgent>") == "&lt;urgent&gt;")
  check('mac escape: " → &quot;', esc('say "hi"') == "say &quot;hi&quot;")
  check("mac escape: ' → &apos;", esc("Bob's task") == "Bob&apos;s task")
  check("mac escape: nil → empty string", esc(nil) == "")
  check("mac escape: number → string", esc(42) == "42")
  -- Critical: & must be escaped FIRST so the substitutions don't double-escape.
  check("mac escape: order — &amp; not &amp;amp;", esc("&") == "&amp;", "got " .. esc("&"))
  check(
    "mac escape: combined `<a&b>` → `&lt;a&amp;b&gt;`",
    esc("<a&b>") == "&lt;a&amp;b&gt;",
    "got " .. esc("<a&b>")
  )
end

-- Tick-agent plist (single agent, N intervals). The title/body escaping
-- still matters for the agent's StandardErrorPath + Label, even though
-- titles/bodies are no longer in the plist (they're in the state JSON).
do
  -- Far-future entries so the assertions don't depend on wall clock.
  local future = os.time() + 86400 * 30 -- ~30 days out
  local plist = mac._tick_plist_body({
    { id = "a", at = future, title = "Standup", body = "in 0" },
    { id = "b", at = future + 3600, title = "Code review", body = "in 1h" },
  })
  check(
    "mac tick plist: well-formed XML declaration",
    plist:find('<?xml version="1.0"', 1, true) == 1
  )
  check("mac tick plist: declares the tick label", plist:find("sh.organ.tick", 1, true) ~= nil)
  check(
    "mac tick plist: StartCalendarInterval array present",
    plist:find("<key>StartCalendarInterval</key>", 1, true) ~= nil
      and plist:find("<array>", 1, true) ~= nil
  )
  check(
    "mac tick plist: 2 interval dicts (one per future entry)",
    select(2, plist:gsub("<key>Year</key>", "")) == 2,
    "got " .. select(2, plist:gsub("<key>Year</key>", "")) .. " Year keys"
  )
  check(
    "mac tick plist: RunAtLoad is false (don't fire on bootstrap)",
    plist:find("<key>RunAtLoad</key>%s*<false/>") ~= nil
  )
  check("mac tick plist: ProgramArguments points at organ-notify", plist:find("organ%-notify"))

  -- Past entries should be skipped (we don't want a calendar interval
  -- whose date is already in the past — launchd would never match it).
  local plist2 = mac._tick_plist_body({
    { id = "old", at = os.time() - 3600, title = "Old", body = "" },
  })
  check(
    "mac tick plist: past-due entries produce zero intervals",
    plist2:find("<key>Year</key>", 1, true) == nil
  )
end

do
  local info = mac._info_plist
  check(
    "mac Info.plist: declares LSUIElement (no Dock icon)",
    info:find("<key>LSUIElement</key>%s*<true/>") ~= nil
  )
  check(
    "mac Info.plist: declares CFBundleIdentifier",
    info:find("<key>CFBundleIdentifier</key>", 1, true) ~= nil
  )
  check("mac notify script: shebang present", mac._notify_script:sub(1, 2) == "#!")
end

-- ---------------------------------------------------------------------------
-- Linux: shell quoting + notify-send command
-- ---------------------------------------------------------------------------
local lin = require("organ.notifier.linux")

do
  local q = lin._shquote
  check("lin shquote: plain string wrapped in single quotes", q("hello") == "'hello'")
  check("lin shquote: empty string → ''", q("") == "''")
  check("lin shquote: nil → ''", q(nil) == "''")
  -- The classic shquote pattern: ' becomes '\'' (close, escaped, reopen).
  check(
    "lin shquote: single quote becomes '\\'' sequence",
    q("Bob's") == [['Bob'\''s']],
    "got " .. q("Bob's")
  )
  -- Critical: shell metachars must NOT escape outside the quotes.
  check(
    "lin shquote: $(rm -rf) stays inside quotes (no command substitution)",
    q("$(rm -rf /)") == "'$(rm -rf /)'",
    "got " .. q("$(rm -rf /)")
  )
  check(
    "lin shquote: ; is inside quotes (no command chaining)",
    q("a; b") == "'a; b'",
    "got " .. q("a; b")
  )
  check("lin shquote: backtick safe inside quotes", q("`whoami`") == "'`whoami`'")
end

do
  local argv = lin._notify_argv("Standup", "in 10 min")
  check("lin notify_argv: argv[1] = notify-send", argv[1] == "notify-send")
  check("lin notify_argv: --app-name=Organ flag", argv[2] == "--app-name=Organ")
  check("lin notify_argv: --icon=organ flag", argv[3] == "--icon=organ")
  check("lin notify_argv: title is positional 4", argv[4] == "Standup")
  check("lin notify_argv: body is positional 5", argv[5] == "in 10 min")
  -- argv path uses no shell, so no escaping needed. Sanity-check that
  -- adversarial input is passed through verbatim (no shell injection
  -- because no shell).
  local mal = lin._notify_argv("$(echo pwn)", "; rm -rf /")
  check("lin notify_argv: malicious title preserved verbatim (no shell)", mal[4] == "$(echo pwn)")
end

do
  local cmd = lin._notify_shell_command("Standup", "in 10 min")
  check("lin notify_shell_command: starts with notify-send", cmd:sub(1, 11) == "notify-send")
  check("lin notify_shell_command: title is shell-quoted", cmd:find("'Standup'", 1, true) ~= nil)
  check("lin notify_shell_command: body is shell-quoted", cmd:find("'in 10 min'", 1, true) ~= nil)
  -- Now the dangerous one: title injection.
  local mal = lin._notify_shell_command("$(echo pwn)", "x")
  check(
    "lin notify_shell_command: title with $(...) is wrapped, not interpolated",
    mal:find("'%$%(echo pwn%)'") ~= nil,
    "got " .. mal
  )
  -- The litmus test: round-trip an adversarial title through /bin/sh.
  -- If shquote is correct, `printf '%s' <quoted>` echoes the literal title
  -- with no command substitution / chaining triggered.
  local function roundtrip(title)
    local quoted = lin._shquote(title)
    local r = vim.system({ "/bin/sh", "-c", "printf %s " .. quoted }, { text = true }):wait()
    return r.code == 0 and r.stdout or nil
  end
  for _, dangerous in ipairs({
    "' && rm -rf / && echo '",
    "$(echo PWNED)",
    "`echo PWNED`",
    "; echo PWNED",
    'Bob\'s mixed "quotes" and $vars',
  }) do
    check(
      "lin shquote: shell-roundtrip preserves " .. dangerous,
      roundtrip(dangerous) == dangerous,
      "got " .. tostring(roundtrip(dangerous))
    )
  end
end

-- ---------------------------------------------------------------------------
-- Windows: PowerShell single-quote escaping
-- ---------------------------------------------------------------------------
local win = require("organ.notifier.windows")

do
  local q = win._ps_quote
  check("win ps_quote: plain → wrapped in single quotes", q("hello") == "'hello'")
  check("win ps_quote: empty → ''", q("") == "''")
  check("win ps_quote: nil → ''", q(nil) == "''")
  -- PowerShell single-quote escape doubles the quote: 'a''b' = a'b literal.
  check("win ps_quote: single quote becomes ''", q("Bob's") == "'Bob''s'", "got " .. q("Bob's"))
  -- $ is NOT special inside PowerShell single-quotes (interpolation only
  -- inside double-quotes). Confirm it survives verbatim.
  check(
    "win ps_quote: $ stays literal inside single quotes",
    q("$(echo pwn)") == "'$(echo pwn)'",
    "got " .. q("$(echo pwn)")
  )
  -- Backtick is the PowerShell escape char inside DOUBLE quotes; inert
  -- inside single quotes — should pass through unmodified.
  check("win ps_quote: backtick stays literal inside single quotes", q("`r`n") == "'`r`n'")
end

do
  -- Probe the toast XML template: it must escape both Title and Body via
  -- SecurityElement::Escape so XML metachars in user input don't break the
  -- toast XML the OS parses.
  check(
    "win NOTIFY_PS1: escapes Title via SecurityElement",
    win._notify_ps1:find("[System.Security.SecurityElement]::Escape($Title)", 1, true) ~= nil
  )
  check(
    "win NOTIFY_PS1: escapes Body via SecurityElement",
    win._notify_ps1:find("[System.Security.SecurityElement]::Escape($Body)", 1, true) ~= nil
  )
  check(
    "win NOTIFY_PS1: invokes ToastNotificationManager",
    win._notify_ps1:find("ToastNotificationManager", 1, true) ~= nil
  )
  check(
    "win NOTIFY_PS1: uses our AUMID for attribution",
    win._notify_ps1:find(win._aumid, 1, true) ~= nil
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("notifier_escaping_test: PASS")
