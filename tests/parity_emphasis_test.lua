-- Emacs parity: inline emphasis recognition.
--
-- Org's emphasis pre/post-char rules (Emacs `org-emphasis-regexp-
-- components') decide what *foo* / /foo/ / _foo_ / +foo+ / ~foo~ /
-- =foo= recognize as emphasis vs treat as plain punctuation.  Easy
-- to get too permissive when porting (e.g. `f*oo*` matches `oo` as
-- bold, which Emacs deliberately does not).
--
-- We dump every recognized emphasis element in document order from
-- both sides and compare.  Element types are normalized to Emacs's
-- names (our grammar uses `strike`, Emacs uses `strike-through`).
--
-- Run via: nvim --headless -l tests/parity_emphasis_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

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

local TYPE_MAP = {
  bold = "bold",
  italic = "italic",
  underline = "underline",
  strike = "strike-through",
  code = "code",
  verbatim = "verbatim",
}

local function inner_text(node, bufnr)
  local t = node:type()
  if t == "code" or t == "verbatim" then
    -- Contents are the full node minus the surrounding delimiters
    -- (~..~ or =..=); match Emacs's `:value` property.
    local full = vim.treesitter.get_node_text(node, bufnr)
    return full:sub(2, -2)
  end
  -- bold/italic/underline/strike: a `plain_text` child carries the
  -- inner text without delimiters.
  for child in node:iter_children() do
    if child:type() == "plain_text" then
      return vim.treesitter.get_node_text(child, bufnr)
    end
  end
  return ""
end

local function our_dump_emphasis(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(input, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  local parser = vim.treesitter.get_parser(b, "org")
  parser:parse(true)
  local hits = {}
  local function walk(lt)
    for _, tree in ipairs(lt:trees()) do
      local function go(n)
        local emacs_type = TYPE_MAP[n:type()]
        if emacs_type then
          local sr, sc = n:start()
          hits[#hits + 1] = {
            sr = sr,
            sc = sc,
            line = string.format("%s\t%s", emacs_type, inner_text(n, b)),
          }
        end
        for c in n:iter_children() do
          go(c)
        end
      end
      go(tree:root())
    end
    for _, child in pairs(lt:children() or {}) do
      walk(child)
    end
  end
  walk(parser)
  table.sort(hits, function(a, b1)
    if a.sr ~= b1.sr then
      return a.sr < b1.sr
    end
    return a.sc < b1.sc
  end)
  local out = {}
  for _, h in ipairs(hits) do
    out[#out + 1] = h.line
  end
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out, "\n") .. "\n"
end

local cases = {
  {
    label = "single bold *bold*",
    input = "Plain *bold* word.\n",
  },
  {
    label = "mid-word `f*oo*bar` MUST NOT recognize bold",
    input = "f*oo*bar in text.\n",
  },
  {
    label = "all six emphasis types on one line (multi-char each)",
    input = "*bold* /italic/ _under_ +strike+ ~code~ =verb= here.\n",
  },
  {
    label = "two bolds in a row are both recognized",
    input = "alpha *one* beta *two* gamma.\n",
  },
  {
    label = "italic next to punctuation",
    input = "say /hi/, then /bye/!\n",
  },
  {
    label = "no emphasis inside a verbatim run",
    input = "=foo *not bold* bar=\n",
  },
  {
    label = "single-char `+s+` strike-through still terminates",
    input = "*b* /i/ _u_ +s+ ~c~ =v= here.\n",
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run("dump-emphasis", c.input)
  local our_out = our_dump_emphasis(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_emphasis_test: PASS")
