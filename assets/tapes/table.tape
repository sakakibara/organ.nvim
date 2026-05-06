# VHS tape: table editing + formula recompute.
#
# What this demo shows, frame by frame:
#   1. table_demo.org open with a 5-column quarterly table.  The
#      Total column is empty.  A `#+TBLFM: $5=$2+$3+$4` line sits
#      directly under the table.
#   2. Cursor lands on the first data cell (Q1 / Region A).  <Tab>
#      walks across cells (auto-realigning columns); <S-Tab> walks
#      back.  Each motion keeps the table cleanly aligned.
#   3. `:Org table eval_formulas` runs the TBLFM: every row's Total
#      is filled in (3 columns summed) and the table re-aligns to
#      fit the new widest column.
#
# Bindings exercised: <Tab> / <S-Tab> for cell navigation in tables,
# `:Org table eval_formulas` for formula recompute (mirrors Emacs
# `org-table-recalculate`, default `C-c *` on a TBLFM line).

Output assets/demos/table.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/table_demo.org"
Enter
Sleep 2250ms
Type "zR"
Sleep 600ms
Show
Sleep 1500ms

# Drop into the first data cell (Q1 row, Region A column).
Type "/1200"
Enter
Sleep 800ms

# Tab walks forward across cells; Shift+Tab walks back.  Realigns
# automatically as the cursor moves.
Tab
Sleep 700ms
Tab
Sleep 700ms
Tab
Sleep 700ms
Shift+Tab
Sleep 700ms
Shift+Tab
Sleep 700ms

# Move down to a different row to show vertical traversal.
Type "j"
Sleep 600ms
Tab
Sleep 700ms
Tab
Sleep 700ms

# Recompute every formula in the TBLFM line: the Total column fills
# in for every row and the table re-aligns.
Type ":Org table eval_formulas"
Enter
Sleep 3000ms

Hide
Type ":qa!"
Enter
