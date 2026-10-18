# GFM footnotes (expected HTML: cmark-gfm form)

## fn_basic

```````````````````````````````` example
Text[^1] and more[^note].

[^1]: First note.
[^note]: Second *note*.
.
<p>Text<sup class="footnote-ref"><a href="#fn-1" id="fnref-1" data-footnote-ref>1</a></sup> and more<sup class="footnote-ref"><a href="#fn-note" id="fnref-note" data-footnote-ref>2</a></sup>.</p>
<section class="footnotes" data-footnotes>
<ol>
<li id="fn-1">
<p>First note. <a href="#fnref-1" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">&#x21a9;</a></p>
</li>
<li id="fn-note">
<p>Second <em>note</em>. <a href="#fnref-note" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="2" aria-label="Back to reference 2">&#x21a9;</a></p>
</li>
</ol>
</section>
````````````````````````````````

## fn_multi

```````````````````````````````` example
A[^a].

[^a]: Para one.

    Para two.

    ```
    code
    ```
.
<p>A<sup class="footnote-ref"><a href="#fn-a" id="fnref-a" data-footnote-ref>1</a></sup>.</p>
<section class="footnotes" data-footnotes>
<ol>
<li id="fn-a">
<p>Para one.</p>
<p>Para two.</p>
<pre><code>code
</code></pre>
<a href="#fnref-a" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">&#x21a9;</a>
</li>
</ol>
</section>
````````````````````````````````

