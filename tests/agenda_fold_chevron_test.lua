-- Each day-header in the agenda buffer registers a fresh fold-open
-- so the statuscolumn chevron renders on every day, not only the
-- first one in a multi-day block.
--
-- Run via: nvim --headless -l tests/agenda_fold_chevron_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "══════════════ block sep ══════════════", -- 1
  "Wednesday   6 May 2026 W19", -- 2
  "  some entry", -- 3
  "  another entry", -- 4
  "Thursday    7 May 2026 W19", -- 5
  "  thursday entry", -- 6
  "Friday      8 May 2026 W19", -- 7
})

-- agenda.foldexpr reads the current buffer; switching is enough.
local function fold_at(l)
  return agenda.foldexpr(l)
end

check("block separator → >1", fold_at(1) == ">1")
check("Wednesday header → >2", fold_at(2) == ">2")
check("Wednesday body → =", fold_at(3) == "=")
check(
  "last line of Wednesday body → 1 (drops level so Thursday opens fresh)",
  fold_at(4) == "1",
  "got " .. tostring(fold_at(4))
)
check("Thursday header → >2", fold_at(5) == ">2")
check(
  "last line of Thursday body → 1 (Friday gets its own chevron)",
  fold_at(6) == "1",
  "got " .. tostring(fold_at(6))
)
check("Friday header → >2", fold_at(7) == ">2")

-- foldlevel must INCREASE between line N (Wed body / Thu body) and
-- line N+1 (Thu header / Fri header) for nvim's status column to
-- draw a chevron.  The `<2` on the body line drops level to 1; the
-- next header's `>2` raises it back to 2.
vim.api.nvim_buf_set_option(b, "foldexpr", "v:lua.require'organ.agenda'.foldexpr(v:lnum)")
vim.api.nvim_buf_set_option(b, "foldmethod", "expr")
vim.cmd("normal! zR") -- open all so foldlevel reflects the expr

local fl_thu_body = vim.fn.foldlevel(6)
local fl_fri_header = vim.fn.foldlevel(7)
check(
  "foldlevel(Friday header) > foldlevel(Thursday body) — chevron will draw",
  fl_fri_header > fl_thu_body,
  ("levels thu_body=%s fri_header=%s"):format(fl_thu_body, fl_fri_header)
)

vim.api.nvim_buf_delete(b, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_fold_chevron_test: PASS")
