-- Normalization for the latex gate (rules and reasons: NORMALIZE.md).
--
-- 1. Emacs's generated labels (`sec:org1a2b3c4`, `org1a2b3c4`, ...) are
--    renamed to the label organ gives the same element: the n-th
--    generated label of a family is paired with organ's n-th label of
--    that family, in order of definition, and every use of it (\ref,
--    \hyperref, label=) is rewritten through the map.  A generated label
--    with no organ partner stays as Emacs wrote it.
-- 2. A run of blank lines becomes one blank line on both sides.
-- 3. Spaces before a line-final `\\` are dropped on both sides, unless
--    a backslash precedes them (a control space).
-- 4. organ's `\frame{\titlepage}` line reads as `\maketitle`.

local root = vim.fn.getcwd()
local area = root .. "/tests/conformance/latex"
local organ = dofile(area .. "/organ.lua")

-- Label definitions in order, as { family, label }.  Emacs's families
-- are its prefixes; a bare `orgXXXXXXX` (targets, radio targets,
-- footnotes) is family "".  organ's footnote labels `fn:N` fall in "".
local function definitions(text)
  local defs = {}
  local pos = 1
  while true do
    local s, e, label = text:find("\\label{([^}]*)}", pos)
    local s2, e2, label2 = text:find("label=({?)", pos)
    if s2 and (not s or s2 < s) then
      local rest = text:sub(e2 + 1)
      label2 = label2 == "{" and rest:match("^([^}]*)}") or rest:match("^([^,%]]*)")
      s, e, label = s2, e2, label2
    end
    if not s then
      return defs
    end
    pos = e + 1
    if label and label ~= "" then
      local family = label:match("^(%a+):") or ""
      if family == "fn" then
        family = ""
      end
      defs[#defs + 1] = { family, label }
    end
  end
end

local function organ_side(case)
  local path = area .. "/cases/" .. case
  local first = (vim.fn.readfile(path, "", 1)[1] or "")
  local option = first:match("^# conformance: beamer ") and "beamer" or nil
  local ok, text = pcall(organ.render, path, option)
  return ok and text or ""
end

local function map_labels(text, case)
  if not text:find("org%x%x%x%x%x%x%x") then
    return text
  end
  local mine, theirs = {}, {}
  local seen = {}
  for _, d in ipairs(definitions(text)) do
    local fam, label = d[1], d[2]
    local generated = label:match("^%a*:?org%x%x%x%x%x%x%x$")
    if generated and not seen[label] then
      seen[label] = true
      mine[fam] = mine[fam] or {}
      table.insert(mine[fam], label)
    end
  end
  seen = {}
  for _, d in ipairs(definitions(organ_side(case))) do
    if not seen[d[2]] then
      seen[d[2]] = true
      theirs[d[1]] = theirs[d[1]] or {}
      table.insert(theirs[d[1]], d[2])
    end
  end
  local map = {}
  for fam, list in pairs(mine) do
    for i, label in ipairs(list) do
      local other = theirs[fam] and theirs[fam][i]
      if other then
        map[label] = other
      end
    end
  end
  return (text:gsub("([%a]*:?org%x%x%x%x%x%x%x)", function(id)
    return map[id]
  end))
end

-- Environments whose lines print as they are.
local VERBATIM = { verbatim = true, Verbatim = true, lstlisting = true, minted = true }

local function squeeze(text)
  local out, blank, verbatim = {}, false, nil
  for _, raw in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = raw
    if verbatim then
      if raw:find("\\end{" .. verbatim .. "}") then
        verbatim = nil
      end
      out[#out + 1] = line
      blank = false
    else
      local env = raw:match("\\begin{(%a+)}")
      if env and VERBATIM[env] and not raw:find("\\end{" .. env .. "}") then
        verbatim = env
      else
        line = raw:gsub("([^\\]) +(\\\\)$", "%1%2")
      end
      if line == "" then
        if not blank then
          out[#out + 1] = line
        end
        blank = true
      else
        out[#out + 1] = line
        blank = false
      end
    end
  end
  return table.concat(out, "\n")
end

return function(text, side, case)
  if side == "emacs" then
    text = map_labels(text, case)
  else
    text = text:gsub("\\frame{\\titlepage}\n", "\\maketitle\n")
  end
  return squeeze(text)
end
