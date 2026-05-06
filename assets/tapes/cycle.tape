# VHS tape: <S-Tab> global cycle + <Tab> per-heading cycle.
#
# What this demo shows, frame by frame:
#   1. cycle_demo.org open with #+title, #+filetags, file-level
#      property drawer, and three top-level headings, each with
#      sub-headings + body.  Drawers start collapsed (Emacs
#      default).  Outline fully expanded (zR'd in DemoBoot).
#   2. <S-Tab> -> OVERVIEW.  Only top-level headings remain
#      visible.  Pre-heading content (#+title, #+filetags, file
#      property drawer) stays visible -- mirrors Emacs behavior
#      where <S-Tab> doesn't hide content above the first
#      level-1 headline.
#   3. <S-Tab> -> CONTENTS.  Every heading at every depth
#      becomes visible; body lines (descriptions, sub-task body)
#      are hidden via conceal_lines extmarks.  Visually equal to
#      "headings only" without losing sub-section structure.
#   4. <S-Tab> -> SHOW_ALL.  Everything visible again.
#   5. Move cursor to `* Project Atlas`.  <Tab> on the heading
#      cycles its individual visibility:
#        FOLDED -> CHILDREN -> SUBTREE
#      (Emacs `org-cycle`).  Sub-tree manipulation per-heading
#      without touching siblings.

Output assets/demos/cycle.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/cycle_demo.org"
Enter
Sleep 2250ms
Type "zR"
Sleep 600ms
Show
Sleep 1500ms

# <S-Tab> #1 -> OVERVIEW.
Shift+Tab
Sleep 1800ms

# <S-Tab> #2 -> CONTENTS.  All headings visible, body hidden.
Shift+Tab
Sleep 2400ms

# <S-Tab> #3 -> SHOW_ALL.
Shift+Tab
Sleep 1500ms

# <Tab> on a top-level heading: cycle that heading individually.
Type "/Project Atlas"
Enter
Sleep 600ms
Type "0"
Sleep 600ms

# 1st <Tab>: FOLDED  (subtree collapses to one line).
Tab
Sleep 1500ms
# 2nd <Tab>: CHILDREN  (sub-headings visible, deeper hidden).
Tab
Sleep 1500ms
# 3rd <Tab>: SUBTREE  (everything visible).
Tab
Sleep 2000ms

Hide
Type ":qa!"
Enter
