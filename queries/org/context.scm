; nvim-treesitter-context reads `queries/<lang>/context.scm` to build its
; sticky header.  A `headline` node's first line is its `* title` line and
; headlines nest, so capturing them shows the full ancestor heading chain --
; the org analog of markdown's `(section (atx_heading))`.
(headline) @context
