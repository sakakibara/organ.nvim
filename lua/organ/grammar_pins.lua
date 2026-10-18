-- The grammar revisions this version of organ is tested with.
-- grammar_install reads this file from disk on each use, so a build hook
-- that runs after an update builds the new pins even while the previous
-- organ code is still loaded.
return {
  ["tree-sitter-organ"] = "9d0c7ca31355b38c6cc5d67ce9c39087720d3f92",
  ["tree-sitter-organ-inline"] = "de0540d9b56e2a19fce95d393f3da4ef7a2b76de",
}
