# Hard breaks, entities, code spans, nested emphasis, thematic breaks, reference-only and trailing-blank input (expected HTML: cmark-gfm form)

## hard_breaks

```````````````````````````````` example
a  
b\
c
.
<p>a<br />
b<br />
c</p>
````````````````````````````````

## entity_named

```````````````````````````````` example
&copy; &nbsp; &amp; &lt;b&gt; &#42;
.
<p>©   &amp; &lt;b&gt; *</p>
````````````````````````````````

## code_tilde_inside

```````````````````````````````` example
`a~b` and `x=y` and `~`
.
<p><code>a~b</code> and <code>x=y</code> and <code>~</code></p>
````````````````````````````````

## code_backtick_inside

```````````````````````````````` example
`` a`b ``
.
<p><code>a`b</code></p>
````````````````````````````````

## bold_italic

```````````````````````````````` example
***both*** and **_mix_**
.
<p><em><strong>both</strong></em> and <strong><em>mix</em></strong></p>
````````````````````````````````

## thematic_variants

```````````````````````````````` example
***

___

- - -
.
<hr />
<hr />
<hr />
````````````````````````````````

## ref_def_only

```````````````````````````````` example
[x]: http://x.com
.
````````````````````````````````

## tab_in_text

```````````````````````````````` example
a	b
.
<p>a	b</p>
````````````````````````````````

## blank_lines_end

```````````````````````````````` example
a



.
<p>a</p>
````````````````````````````````

