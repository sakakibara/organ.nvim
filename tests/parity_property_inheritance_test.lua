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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_property_inheritance_test: PASS")
