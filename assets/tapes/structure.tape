# VHS tape: outline structure manipulation (<M-h/j/k/l>).
#
# What this demo shows, frame by frame:
#   1. structure_demo.org open with three top-level headings; the
#      middle one has nested sub-tasks + deep detail.
#   2. Cursor on `* Middle entry`.  <M-k> moves the entire subtree
#      UP -- "Middle entry" + its sub-tasks swap with "Top of the
#      list".  Re-levelling preserved.
#   3. <M-l> demotes the subtree (level 1 -> level 2): the whole
#      block now sits under the heading above it.  Sub-tasks
#      cascade (level 2 -> 3, level 3 -> 4).
#   4. <M-h> promotes back to level 1.  Same reversed.
#   5. <M-j> moves the subtree DOWN, past the next heading.
#
# All four bindings are single-chord; the subtree-aware variants
# of vim's `<<` / `>>` / `gK` / `gJ` operate on the cursor's
# whole heading + descendants.  Mirrors Emacs's `M-<arrow>`
# subtree manipulation.

Output assets/demos/structure.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/structure_demo.org"
Enter
Sleep 2250ms
Type "zR"
Sleep 600ms
Show
Sleep 1500ms

# Land on `* Middle entry`.
Type "/Middle entry"
Enter
Sleep 600ms
Type "0"
Sleep 600ms

# <M-k>: move subtree up.
Alt+k
Sleep 1500ms

# <M-l>: demote subtree (level 1 -> 2; sub-tasks cascade deeper).
Alt+l
Sleep 1800ms

# <M-h>: promote back.
Alt+h
Sleep 1500ms

# <M-j>: move subtree down past the next heading.
Alt+j
Sleep 2000ms

Hide
Type ":qa!"
Enter
