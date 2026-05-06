# VHS tape: archive a subtree.
#
# What this demo shows, frame by frame:
#   1. archive_demo.org open with three top-level entries:
#      - DONE Ship the v1 release  (CLOSED, ready to archive)
#      - TODO Audit the deps        (live, stays put)
#      - DONE Plan the v2 kickoff   (CLOSED, also archivable)
#   2. Cursor on `* DONE Ship the v1 release`.  `:Org archive`
#      moves the entire subtree (heading, planning line, drawer,
#      body) out of the live file into the archive sibling
#      (archive_demo.org_archive by default), preserving the path
#      via an :ARCHIVE_OLPATH: property.
#   3. Source file shrinks: the DONE entry is gone, only the TODO
#      and the second DONE remain.
#   4. Open the archive sibling in a vsplit on the right -- the
#      v1-release subtree appears at the top, with the
#      :ARCHIVE_OLPATH: property recording where it came from.
#
# The archive sibling is `<file>.org_archive` by default; mirrors
# Emacs's `org-archive-location` default `%s_archive::`.

Output assets/demos/archive.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/archive_demo.org"
Enter
Sleep 2250ms
Type "zR"
Sleep 600ms
Show
Sleep 1500ms

# Land on the first DONE heading (line 3).
Type "/Ship the v1 release"
Enter
Sleep 600ms
Type "0"
Sleep 600ms

# Archive the subtree.
Type ":Org archive"
Enter
Sleep 2500ms

# Open the archive sibling beside it so the moved subtree is
# visible alongside the now-shrunk source file.
Type ":vsplit archive_demo.org_archive"
Enter
Sleep 1200ms
Type "zR"
Sleep 3500ms

Hide
Type ":qa!"
Enter
