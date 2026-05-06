# VHS tape: refile flow.
#
# What this demo shows, frame by frame:
#   1. Two panes open side by side:
#      - LEFT  = projects.org with two `** Backlog` headings
#                (one under `* organ.nvim`, one under `* personal`)
#      - RIGHT = refile_source.org with one TODO headline +
#                multi-line body + a `** Subtasks` section
#                (3 sub-headlines).  The full subtree is the
#                refile candidate.
#   2. User triggers `:Org refile` from the right pane (cursor on
#      the TODO).  Snacks picker opens centered.
#   3. User types `organ Backlog` -> picker filters to ONE entry:
#      `** Backlog projects.org/organ.nvim`.  (The other Backlog
#      under `personal` is filtered out by the `organ` token.)
#      The breadcrumb after the heading shows `<file>/<parent>` --
#      Emacs's `org-refile-use-outline-path = 'file` format.
#   4. <Enter> fires.  Picker closes.  At that moment:
#      - LEFT pane's `** Backlog` under `* organ.nvim` gains the
#        moved subtree (re-leveled to *** / **** / *****).
#      - RIGHT pane (the source) is now empty except for #+TITLE.
#   5. Final pause: viewer can read both panes side by side and
#      see the move plainly.  Source file (right) shows the
#      headline IS gone; target (left) shows the headline IS
#      under the right Backlog.

Output assets/demos/refile.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/refile_source.org"
Enter
Sleep 2250ms
# Open projects.org in a vsplit (lands on the LEFT, current pane
# becomes refile_source.org on the RIGHT).  Unfold both panes so
# every line is visible from frame 1.
Type ":vsplit "
Sleep 300ms
# DemoBoot does `lcd $tmpdir/org`, so bare basenames open the tmp
# copies (the same files the picker / refile operate on).  Using
# the original tests/fixtures/demos/ path here would open the
# TRACKED fixture and refile would silently mutate a different
# buffer that's not on screen.
Type "projects.org"
Enter
Sleep 1200ms
Type "zR"
Sleep 600ms
Ctrl+w
Type "l"
Sleep 300ms
Type "zR"
Show
Sleep 1500ms

# Position cursor on the TODO headline (line 1 -> #+TITLE isn't a
# headline, refile would error 'no headline at or above cursor').
Type "gg"
Sleep 300ms
Type "/TODO"
Enter
Sleep 300ms

# Trigger refile.  Picker opens centered with all candidate
# headlines.  Type to filter to the organ.nvim Backlog
# specifically -- "Backlog" alone matches BOTH Backlogs (under
# organ.nvim AND under personal); adding "organ" disambiguates.
Type ":Org refile"
Enter
Sleep 1800ms
Type "organ Backlog"
Sleep 1500ms
Enter
Sleep 2250ms

# Move focus to the LEFT pane (projects.org) and unfold so the
# moved subtree is visible under organ.nvim's Backlog.  Without
# this, the target stays in whatever fold state it had at refile
# time and the new content is hidden inside a `Backlog` fold.
Ctrl+w
Type "h"
Sleep 450ms
Type "zR"
Sleep 4500ms

Hide
Type ":qa!"
Enter
