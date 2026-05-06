# VHS tape: org-roam flow.
#
# What this demo shows, frame by frame:
#   1. multi_sequence.org open + unfolded.  Body has a link
#      `[[id:organ-nvim][organ.nvim]]` -- in the rendered buffer
#      this shows as just `organ.nvim` (link concealment is on).
#   2. `:Org roam buffer` opens the backlinks sidebar on the right.
#      Two backlinks appear: organ.nvim and personal (both link
#      to this multi-sequence node via `[[id:multi-sequence]]`).
#      Each entry is two lines: `• Title` + indented
#      `basename · Lnnn` location.
#   3. `:Org roam` opens the node picker.  User types `organ`
#      to filter, presses Enter.  Picker closes; the buffer
#      switches to projects.org and the cursor lands on the
#      `* organ.nvim` headline.

Output assets/demos/roam.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/multi_sequence.org"
Enter
Sleep 2250ms
# Unfold so viewer sees the full node body (description prose +
# the link back to organ.nvim) before the sidebar opens.
Type "zR"
Sleep 300ms
Show

# Open the roam sidebar -- two backlinks appear (organ.nvim and
# personal both link to this node via id:multi-sequence).
Type ":Org roam buffer"
Enter
Sleep 3750ms

# Find a node by name.  Snacks picker opens; the test fixture has
# 3 ID-tagged nodes, type 'organ' to filter.
Type ":Org roam"
Enter
Sleep 1500ms
Type "organ"
Sleep 2250ms
Enter
Sleep 3750ms

Hide
Type ":qa!"
Enter
