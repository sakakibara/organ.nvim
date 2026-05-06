# VHS tape: agenda demo.
#
# What this demo shows, frame by frame:
#   1. Source org file unfolded (8 entries across the week).
#   2. `:Org agenda week` opens the week-view buffer with day
#      headers, time grid, scheduled / DONE / NEXT / WAIT rows
#      colored per their state, priority cookies ([#A] / [#B]),
#      tags right-aligned.
#   3. `l` toggles log mode -- the DONE entries (with CLOSED:
#      timestamps) appear inline under the day they were closed.
#   4. `jj` moves cursor down to a TODO row.
#   5. `t` cycles its state in-place -- TODO -> WAIT -> NEXT.
#      The state changes ARE in the agenda buffer (no jump back to
#      source needed); written through to the source file.
#   6. `gd` switches to day view (single day).
#   7. `gw` returns to the week view.

Output assets/demos/agenda.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/agenda_demo.org"
Enter
Sleep 2250ms
# Unfold the source file BEFORE Show so viewers see all entries
# from frame 1 instead of '* * * * * 8 items hidden' overview-fold
# placeholders.  Agenda buffer itself isn't folded, but the source
# file briefly flashes pre-:Org-agenda.
Type "zR"
Sleep 300ms
Show

# Open the week agenda — visible cmdline shows the command typing.
Type ":Org agenda week"
Enter
Sleep 3750ms

# Toggle log mode: the DONE entries (CLOSED:) appear inline under
# the day they were closed.
Type "l"
Sleep 3750ms

# Move down to a TODO row and cycle its state in-place from the
# agenda buffer (no need to jump to source).
Type "jj"
Sleep 1200ms
Type "t"
Sleep 2250ms
Type "t"
Sleep 2250ms

# Switch to the day view of the highlighted day.
Type "gd"
Sleep 3750ms

# Back to week view.
Type "gw"
Sleep 2700ms

Hide
Type "q"
Type ":qa!"
Enter
