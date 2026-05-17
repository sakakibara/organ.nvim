-- Emacs parity: property inheritance.
--
-- `:CATEGORY:` is the canonical always-inheriting org property
-- (Emacs `org-entry-get nil "CATEGORY" t`).  Resolution order:
--   1. Own `:CATEGORY:` in this heading's PROPERTIES drawer
--   2. Nearest ancestor's `:CATEGORY:`
--   3. File-level `#+CATEGORY:` directive
--   4. Filename (without .org) -- skipped here; we test buffer-only
--
-- Limited to CATEGORY for now; the `:KEY+:` append-list syntax and
-- per-property `org-use-property-inheritance` configuration land in
-- follow-up tests.
--
-- Run via: nvim --headless -l tests/parity_property_inheritance_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local TODO_KEYWORDS = { TODO = 1, NEXT = 1, WAIT = 1, HOLD = 1, PROJ = 1, DONE = 1, CANCELLED = 1 }

local function heading_text(rest)
  -- Strip a trailing :tag:tag: block, then a leading TODO keyword.
  rest = rest:gsub("%s+:[%w_@#%%:]+:%s*$", "")
  local first = rest:match("^(%S+)")
  if first and TODO_KEYWORDS[first] then
    rest = rest:gsub("^" .. first .. "%s+", "")
  end
  return rest
end

local function find_own_category(lines, i)
  -- Walk forward from line i+1 until next headline or EOF; if a line
  -- inside a :PROPERTIES: drawer matches `:CATEGORY: value`, return it.
  local j = i + 1
  while j <= #lines and not lines[j]:match("^%*+%s") do
    local v = lines[j]:match("^%s*:CATEGORY:%s*(.-)%s*$")
    if v and v ~= "" then
      return v
    end
    j = j + 1
  end
  return nil
end

-- Walk forward from the headline at line i, return:
--   own       = value of `:KEY:` (override) or nil
--   appended  = value of `:KEY+:` (appends to inherited) or nil
-- `:KEY:` set overrides the inherited value; `:KEY+:` appends to it
-- (Emacs `org-entry-get` with INHERIT=t resolves the chain top-down).
local function find_own_property(lines, i, key)
  local own, appended
  local own_re = "^%s*:" .. key .. ":%s*(.-)%s*$"
  local plus_re = "^%s*:" .. key .. "%+:%s*(.-)%s*$"
  local j = i + 1
  while j <= #lines and not lines[j]:match("^%*+%s") do
    local v_own = lines[j]:match(own_re)
    if v_own and v_own ~= "" then
      own = v_own
    end
    local v_plus = lines[j]:match(plus_re)
    if v_plus and v_plus ~= "" then
      appended = v_plus
    end
    j = j + 1
  end
  return own, appended
end

local function our_dump_property(input)
  local lines = vim.split(input, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  local file_cat
  for _, l in ipairs(lines) do
    local cat = l:match("^#%+CATEGORY:%s*(.-)%s*$")
    if cat and cat ~= "" then
      file_cat = cat
      break
    end
  end
  local effective_at = {}
  local out = {}
  for i, line in ipairs(lines) do
    local stars, rest = line:match("^(%*+)%s+(.*)$")
    if stars then
      local depth = #stars
      local heading = heading_text(rest)
      local own = find_own_category(lines, i)
      local effective = own
      if not effective then
        for d = depth - 1, 1, -1 do
          if effective_at[d] then
            effective = effective_at[d]
            break
          end
        end
      end
      if not effective then
        effective = file_cat
      end
      effective_at[depth] = effective
      for d = depth + 1, #effective_at do
        effective_at[d] = nil
      end
      out[#out + 1] = string.format("%s\t%s", heading, effective or "")
    end
  end
  return table.concat(out, "\n") .. "\n"
end

local cases = {
  {
    label = "file-level #+CATEGORY: applies to all entries",
    input = "#+CATEGORY: file-cat\n* Top\n* Sibling\n",
  },
  {
    label = "own :CATEGORY: overrides file-level",
    input = "#+CATEGORY: file-cat\n* Override\n:PROPERTIES:\n:CATEGORY: own-cat\n:END:\n",
  },
  {
    label = "child inherits parent's :CATEGORY: override",
    input = "#+CATEGORY: file-cat\n* Parent\n:PROPERTIES:\n:CATEGORY: parent-cat\n:END:\n** Child\n",
  },
  {
    label = "sibling at parent's depth does NOT inherit prior subtree's :CATEGORY:",
    input = "#+CATEGORY: file-cat\n* Parent\n:PROPERTIES:\n:CATEGORY: parent-cat\n:END:\n** Child\n* SiblingOfParent\n",
  },
  {
    label = "three-level chain: grandchild inherits root's :CATEGORY:",
    input = "#+CATEGORY: file-cat\n* Top\n:PROPERTIES:\n:CATEGORY: top-cat\n:END:\n** Mid\n*** Leaf\n",
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run("dump-property", c.input)
  local our_out = our_dump_property(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

-- ---------------------------------------------------------------------------
-- `:KEY+:` append syntax: child's `+` value appends (space-joined) to
-- parent's effective value, instead of overriding it.  Used for things
-- like `:LATEX_HEADER+:` where multiple `\usepackage{...}` lines
-- accumulate down the tree.  `org-entry-get nil KEY t` resolves the
-- full chain.  Requires `org-use-property-inheritance` to be enabled
-- (`t` for all properties, or a list / regex including KEY) on the
-- Emacs side -- our test fixture uses `LATEX_HEADER` which is in the
-- list of properties Emacs inherits by default for org-mode use.
-- ---------------------------------------------------------------------------
local function our_dump_property_plus(input, key)
  local lines = vim.split(input, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  local effective_at = {}
  local out = {}
  for i, line in ipairs(lines) do
    local stars, rest = line:match("^(%*+)%s+(.*)$")
    if stars then
      local depth = #stars
      local heading = heading_text(rest)
      local own, appended = find_own_property(lines, i, key)
      local inherited
      for d = depth - 1, 1, -1 do
        if effective_at[d] then
          inherited = effective_at[d]
          break
        end
      end
      local effective
      if own then
        effective = own
        if appended then
          effective = effective .. " " .. appended
        end
      elseif appended then
        effective = inherited and (inherited .. " " .. appended) or appended
      else
        effective = inherited
      end
      effective_at[depth] = effective
      for d = depth + 1, #effective_at do
        effective_at[d] = nil
      end
      out[#out + 1] = string.format("%s\t%s", heading, effective or "")
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- Emacs needs `LATEX_HEADER` to inherit.  Since it's not in
-- `org-use-property-inheritance`'s default value, the emacs-op call
-- has to enable inheritance explicitly.  We do that via a separate
-- op `dump-property-inherited` that sets the var before scanning.
-- Until that op exists, use a property name Emacs DOES inherit by
-- default: `CATEGORY` doesn't take `+` semantics, but `ARCHIVE` does
-- and is in the default inheritance set.  Probe-confirmed below.
local append_cases = {
  {
    label = "parent has own, child appends with `:KEY+:`",
    input = "* Parent\n:PROPERTIES:\n:ARCHIVE: alpha\n:END:\n** Child\n:PROPERTIES:\n:ARCHIVE+: beta\n:END:\n",
  },
  {
    label = "grandchild without `+` inherits parent's already-appended value",
    input = "* Top\n:PROPERTIES:\n:ARCHIVE: a\n:END:\n** Mid\n:PROPERTIES:\n:ARCHIVE+: b\n:END:\n*** Leaf\n",
  },
  {
    label = "child overrides parent (no `+`)",
    input = "* Parent\n:PROPERTIES:\n:ARCHIVE: alpha\n:END:\n** Child\n:PROPERTIES:\n:ARCHIVE: gamma\n:END:\n",
  },
}

for _, c in ipairs(append_cases) do
  -- Inject the property name into the Emacs side via the op param.
  -- emacs-op.el reads `organ-op--property` from --eval before running
  -- the dump-property op.
  local emacs_out =
    parity.run_with_setup("dump-property", c.input, '(setq organ-op--property "ARCHIVE")')
  local our_out = our_dump_property_plus(c.input, "ARCHIVE")
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_property_inheritance_test: PASS")
