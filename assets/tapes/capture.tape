# VHS tape: capture flow.
#
# What this demo shows, frame by frame:
#   1. inbox.org unfolded -- shows just `* Inbox` (no children).
#   2. `:Org capture` opens the centered template picker with 3
#      entries: `[t] Task`, `[n] Note`, `[b] Bookmark`.
#   3. User presses `t` -> Task template selected.  A capture
#      float opens (centered, 80% wide), pre-filled with `* TODO `
#      and an inactive timestamp, cursor in insert mode at the
#      `%?` position right after `* TODO `.
#   4. User types the task body.
#   5. `<Esc>` then `ZZ` finalizes (vim convention -- 'save and
#      close').  Float closes.
#   6. Final pause: inbox.org now shows the captured entry as a
#      CHILD of `* Inbox` (re-leveled to `**` per Emacs parity)
#      with the captured-at timestamp on the next line.

Output assets/demos/capture.gif

Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 150ms
Set Padding 20

Hide
Type "nvim -u tests/fixtures/demos/minimal_init.lua -c 'lua DemoBoot()' tests/fixtures/demos/inbox.org"
Enter
Sleep 2250ms
# Unfold the source file BEFORE Show so the viewer can see the
# initial inbox.org state (just '* Inbox' with no children) and
# then watch the captured entry land underneath.
Type "zR"
Sleep 300ms
Show

# Open the picker.  Visible 3-template float appears centered.
Type ":Org capture"
Enter
Sleep 2250ms

# Pick the Task template.
Type "t"
Sleep 1500ms

# Type the body.
Type "Wire up VHS demo automation"
Sleep 1500ms

# Finalize: capture opens in insert mode.  Escape, then ZZ (vim's
# 'save and close') -- organ's default finalise binding.  '<CR>' in
# normal mode also finalises (finalise_alt); ZZ is the more vim-
# native demo.
Escape
Sleep 300ms
Type "ZZ"
Sleep 2250ms

# Show the captured entry landed in inbox.org.  ZR opens all folds
# so the new entry is visible without manual unfolding.
Type "zR"
Sleep 3000ms

Hide
Type ":qa!"
Enter
