(bold) @markup.bold

(italic) @markup.italic

(underline) @markup.underline

(strike) @markup.strikethrough

(code) @markup.raw.inline

(verbatim) @markup.raw.inline

(link_regular) @markup.link
(link_regular target:      (link_target)      @markup.link.url)
(link_regular description: (link_description) @markup.link.label)

(link_angle) @markup.link.url
(link_angle target: (link_target) @markup.link.url)

(link_plain) @markup.link.url
(link_plain target: (link_target) @markup.link.url)

(link_radio) @markup.link
(link_radio target: (link_target) @markup.link.url)

(timestamp_active) @markup.italic
(timestamp_active date: (ts_date) @org.timestamp.date)
(timestamp_active (ts_time) @org.timestamp.time)
(timestamp_active (ts_dayname) @org.timestamp.dayname)
(timestamp_active (ts_repeater) @org.timestamp.repeater)
(timestamp_active (ts_repeater_alarm) @org.timestamp.repeater.alarm)
(timestamp_active (ts_repeater_filter) @org.timestamp.repeater.filter)
(timestamp_active (ts_warning) @org.timestamp.warning)

(timestamp_inactive) @comment
(timestamp_inactive date: (ts_date) @org.timestamp.date)
(timestamp_inactive (ts_time) @org.timestamp.time)
(timestamp_inactive (ts_dayname) @org.timestamp.dayname)
(timestamp_inactive (ts_repeater) @org.timestamp.repeater)
(timestamp_inactive (ts_repeater_alarm) @org.timestamp.repeater.alarm)
(timestamp_inactive (ts_repeater_filter) @org.timestamp.repeater.filter)
(timestamp_inactive (ts_warning) @org.timestamp.warning)

(timestamp_diary)        @org.timestamp.diary
(timestamp_range_active) @org.timestamp.range
(timestamp_range_inactive) @org.timestamp.range

(citation)            @org.citation
(citation_style)      @org.citation.style
(citation_key)        @org.citation.key
(citation_prefix)     @org.citation.prefix
(citation_suffix)     @org.citation.suffix

(citation) @org.citation

; Footnote ref `[fn:LABEL]` / `[fn:LABEL:body]` / anonymous `[fn::body]`.
(footnote_ref) @org.footnote.ref
(footnote_ref label: (footnote_label) @org.footnote.label)
(footnote_ref body:  (footnote_body)  @org.footnote.body)

; Macro `{{{name(arg, ...)}}}` — distinguish name from arguments.
(macro) @org.macro
(macro name:     (macro_name)     @org.macro.name)
(macro argument: (macro_argument) @org.macro.argument)

; Inline src block `src_LANG{body}` / `src_LANG[args]{body}` — break out
; language / header args / body for theme-level styling.
(inline_src_block) @markup.raw.inline
(inline_src_block language:    (inline_src_language) @org.block.language)
(inline_src_block header_args: (inline_src_args)     @org.block.header_args)
(inline_src_block body:        (inline_src_body)     @markup.raw.inline)

; Inline babel call `call_NAME[hdr](args)[end]`.
(inline_babel_call) @org.babel_call
(inline_babel_call name:          (inline_call_name) @org.babel_call.name)
(inline_babel_call inside_header: (inline_call_args) @org.block.header_args)
(inline_babel_call arguments:     (inline_call_args) @org.babel_call.argument)
(inline_babel_call end_header:    (inline_call_args) @org.block.header_args)

(export_snippet) @org.export_snippet

(entity) @org.entity

(latex_fragment) @org.latex

(target) @org.target

(statistics_cookie) @org.statistics

(subscript) @markup.subscript

(superscript) @markup.superscript

(line_break) @markup.raw.inline

(plain_text) @spell
