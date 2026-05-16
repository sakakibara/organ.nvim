-- Emacs parity: tag inheritance.
--
-- A child headline with no direct tags inherits its parent's tag set
-- when `org-use-tag-inheritance' is enabled (Emacs default `t`).
-- `org-tags-exclude-from-inheritance' opts specific tags out.
--
-- We test the in-buffer "effective tags per headline" view.  Emacs's
-- canonical op is `org-get-tags' (returns direct + inherited).  Our
-- side: walk the headline tree, accumulate parent tags top-down.
-- The walker lives in this test for now -- a focused regression test
-- on the inheritance ALGORITHM, independent of the SQL query layer.
--
-- Run via: nvim --headless -l tests/parity_tag_inheritance_test.lua

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

-- Pure-Lua reference: parse the buffer, walk headlines top-down,
-- compute effective tags = parent's effective tags U direct tags.
-- Emits the same "<HEADING>\t<sorted,comma-joined tags>" format as
-- the Emacs `dump-tags` op so byte-diff is straightforward.
local function our_dump_tags(input)
  local lines = vim.split(input, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  -- Stack: per-level tag set inherited from ancestors at each depth.
  local inherited_at = {}
  local out = {}
  for _, line in ipairs(lines) do
    local stars, rest = line:match("^(%*+)%s+(.*)$")
    if stars then
      local depth = #stars
      -- Strip a trailing :tag:tag: block.
      local tag_run = rest:match("%s+(:[%w_@#%%:]+:)%s*$")
      local direct = {}
      if tag_run then
        for t in tag_run:gmatch(":([%w_@#%%]+)") do
          direct[#direct + 1] = t
        end
        rest = rest:gsub("%s+:[%w_@#%%:]+:%s*$", "")
      end
      -- Strip a leading TODO keyword for the heading text (so it
      -- matches `org-get-heading t t t t` which strips state, prio,
      -- comment, tags).
      local heading_text = rest:gsub("^%S+%s+(.*)$", function(s)
        -- only strip if the first word is a TODO keyword
        local first = rest:match("^(%S+)")
        local known = { TODO = 1, NEXT = 1, WAIT = 1, HOLD = 1, PROJ = 1, DONE = 1, CANCELLED = 1 }
        if known[first] then
          return s
        end
        return rest
      end)
      -- Effective = inherited from parent's depth + direct.
      local seen, effective = {}, {}
      for _, t in ipairs(inherited_at[depth - 1] or {}) do
        if not seen[t] then
          seen[t] = true
          effective[#effective + 1] = t
        end
      end
      for _, t in ipairs(direct) do
        if not seen[t] then
          seen[t] = true
          effective[#effective + 1] = t
        end
      end
      -- This headline's effective tags become the inheritance pool
      -- for any child at depth+1.  Clear deeper levels (sibling cuts
      -- off descendants of the previous heading at this depth).
      inherited_at[depth] = effective
      for d = depth + 1, #inherited_at do
        inherited_at[d] = nil
      end
      table.sort(effective)
      out[#out + 1] = string.format("%s\t%s", heading_text, table.concat(effective, ","))
    end
  end
  return table.concat(out, "\n") .. "\n"
end

local cases = {
  {
    label = "level-2 child inherits its parent's tag set",
    input = "* Project :work:\n** Task\n",
  },
  {
    label = "child with its own tag unions with parent's",
    input = "* Project :work:\n** Task :urgent:\n",
  },
  {
    label = "sibling at parent level does not inherit",
    input = "* Project :work:\n** Task\n* Other\n",
  },
  {
    label = "three-level chain: grandchild inherits root's tag",
    input = "* Top :context:\n** Mid\n*** Leaf\n",
  },
  {
    label = "duplicate tag on child + parent: stays once",
    input = "* Project :work:\n** Task :work:\n",
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run("dump-tags", c.input)
  local our_out = our_dump_tags(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_tag_inheritance_test: PASS")
