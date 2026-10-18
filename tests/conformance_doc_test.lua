-- Doc-only conformance entries: claims about Emacs that were false must
-- stay out of doc/organ.txt, and the corrected text must stay in.

local root = vim.fn.getcwd()
local doc = table.concat(vim.fn.readfile(root .. "/doc/organ.txt"), "\n")

local failures = 0
local function absent(id, text)
  if doc:find(text, 1, true) then
    failures = failures + 1
    io.write(string.format("FAIL %s: doc still says %q\n", id, text))
  end
end
local function present(id, text)
  if not doc:find(text, 1, true) then
    failures = failures + 1
    io.write(string.format("FAIL %s: doc lost %q\n", id, text))
  end
end

absent("DOC-1", "Emacs: Prompts keep / stop / cancel.")
absent("DOC-11", "Emacs: `|` typing AND `<Tab>`.")
absent("DOC-13", "Why: Practical 80%; full Calc rarely needed")
absent("DOC-15", "Shows `vim.ui.select` only when `agenda.views` is")
absent("DOC-15", "skips the dispatcher when there's")
present("DOC-15", "With no argument, shows the agenda\n    dispatcher")

if failures > 0 then
  os.exit(1)
end
io.write("conformance doc ok\n")
