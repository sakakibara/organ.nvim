; Inline textobjects live in the org_inline injected tree (links, emphasis
; and timestamps are parsed there, not in the block-level `org` grammar).
; Namespaced @org.* to match the block-level textobjects query.

; Links; inner is the description text (the human-readable part of
; `[[target][description]]`) when present.
[
  (link_regular)
  (link_angle)
  (link_plain)
  (link_radio)
] @org.link.outer
(link_regular (link_description) @org.link.inner)

; Timestamps of every flavor.
[
  (timestamp_active)
  (timestamp_inactive)
  (timestamp_diary)
  (timestamp_range_active)
  (timestamp_range_inactive)
] @org.timestamp.outer

; Emphasis spans.
(bold) @org.emphasis.outer
(italic) @org.emphasis.outer
(code) @org.emphasis.outer
(verbatim) @org.emphasis.outer
(strike) @org.emphasis.outer
(underline) @org.emphasis.outer
