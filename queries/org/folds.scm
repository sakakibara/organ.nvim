(headline)            @fold
(inlinetask)          @fold
(property_drawer)     @fold
(drawer)              @fold
(footnote_definition) @fold
(latex_environment)   @fold
; Block fold targets — only node types the grammar exposes. quote/center
; etc. are wrapped under greater_block, so they fold via that capture.
(src_block)           @fold
(example_block)       @fold
(verse_block)         @fold
(export_block)        @fold
(comment_block)       @fold
(greater_block)       @fold
(dynamic_block)       @fold
