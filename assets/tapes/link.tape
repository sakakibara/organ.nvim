# VHS tape: link follow + back.
#
# What this demo shows, frame by frame:
#   1. link_demo.org open with two outbound links: a `file:` link
#      to `link_target.org` and an in-file `*Glossary` link.
#   2. Cursor on the file link -- <CR> follows it; vim opens
#      link_target.org in place.  Title bar / buffer changes; the
#      cursor lands at the top of the target file.
#   3. <C-o> returns to the previous location via vim's jumplist;
#      we're back in link_demo.org with the cursor where it left.
#   4. Cursor on the `*Glossary` heading link -- <CR> jumps to the
#      Glossary heading further down THIS buffer.  <C-o> returns.
#
# Bindings exercised: <CR> => `:Org follow_link` (also bound to
# `gx`).  Inverse is vim-native (`<C-o>` walks the jumplist back).

Output assets/demos/link.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/link_demo.org"
Enter
Sleep 2250ms
Type "zR"
Sleep 600ms
Show
Sleep 1500ms

# Land on the file: link and follow it.
Type "/file:link_target"
Enter
Sleep 800ms
Enter
Sleep 2000ms

# Return via the jumplist.
Ctrl+o
Sleep 1500ms

# Land on the in-file `*Glossary` heading link and follow it.
# `jump-to-glossary` is the description text inside the
# [[*Glossary][...]] link, unique in the buffer (vim's `/` would
# need to escape the literal `*` to land on the target itself).
Type "/jump-to-glossary"
Enter
Sleep 800ms
Enter
Sleep 2000ms

# Return.
Ctrl+o
Sleep 1500ms

Hide
Type ":qa!"
Enter
