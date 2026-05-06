# VHS tape: babel flow.
#
# What this demo shows, frame by frame:
#   1. babel_demo.org open with one Lua source block computing
#      `pow(2, 10)`.  Block body is syntax-highlighted via the
#      tree-sitter Lua injection (Lua parser is built into Neovim
#      so the demo doesn't need any extra parser install).
#   2. Cursor moves into the block (/begin_src then j).
#   3. `:Org babel execute` runs the block.  The result (1024)
#      lands as `#+RESULTS:` + a `: 1024` line directly below the
#      `#+end_src`.

Output assets/demos/babel.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/babel_demo.org"
Enter
Sleep 2250ms
Show

# Move into the src block.  `/begin_src` matches the opener
# regardless of which language we render -- searching for code-
# specific tokens (like `print`) breaks the demo every time we
# tweak the example.
Type "/begin_src"
Enter
Sleep 600ms
Type "j"
Sleep 300ms

# Execute the block; result lands below.
Type ":Org babel execute"
Enter
Sleep 3s

Hide
Type ":qa!"
Enter
