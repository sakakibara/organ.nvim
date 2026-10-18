# CommonMark 0.31.2 spec, section "Entity and numeric character references"

## example 25

```````````````````````````````` example
&nbsp; &amp; &copy; &AElig; &Dcaron;
&frac34; &HilbertSpace; &DifferentialD;
&ClockwiseContourIntegral; &ngE;
.
<p>  &amp; © Æ Ď
¾ ℋ ⅆ
∲ ≧̸</p>
````````````````````````````````

## example 26

```````````````````````````````` example
&#35; &#1234; &#992; &#0;
.
<p># Ӓ Ϡ �</p>
````````````````````````````````

## example 27

```````````````````````````````` example
&#X22; &#XD06; &#xcab;
.
<p>&quot; ആ ಫ</p>
````````````````````````````````

## example 28

```````````````````````````````` example
&nbsp &x; &#; &#x;
&#87654321;
&#abcdef0;
&ThisIsNotDefined; &hi?;
.
<p>&amp;nbsp &amp;x; &amp;#; &amp;#x;
&amp;#87654321;
&amp;#abcdef0;
&amp;ThisIsNotDefined; &amp;hi?;</p>
````````````````````````````````

## example 29

```````````````````````````````` example
&copy
.
<p>&amp;copy</p>
````````````````````````````````

## example 30

```````````````````````````````` example
&MadeUpEntity;
.
<p>&amp;MadeUpEntity;</p>
````````````````````````````````

## example 31

```````````````````````````````` example
<a href="&ouml;&ouml;.html">
.
<a href="&ouml;&ouml;.html">
````````````````````````````````

## example 32

```````````````````````````````` example
[foo](/f&ouml;&ouml; "f&ouml;&ouml;")
.
<p><a href="/f%C3%B6%C3%B6" title="föö">foo</a></p>
````````````````````````````````

## example 33

```````````````````````````````` example
[foo]

[foo]: /f&ouml;&ouml; "f&ouml;&ouml;"
.
<p><a href="/f%C3%B6%C3%B6" title="föö">foo</a></p>
````````````````````````````````

## example 34

```````````````````````````````` example
``` f&ouml;&ouml;
foo
```
.
<pre><code class="language-föö">foo
</code></pre>
````````````````````````````````

## example 35

```````````````````````````````` example
`f&ouml;&ouml;`
.
<p><code>f&amp;ouml;&amp;ouml;</code></p>
````````````````````````````````

## example 36

```````````````````````````````` example
    f&ouml;f&ouml;
.
<pre><code>f&amp;ouml;f&amp;ouml;
</code></pre>
````````````````````````````````

## example 37

```````````````````````````````` example
&#42;foo&#42;
*foo*
.
<p>*foo*
<em>foo</em></p>
````````````````````````````````

## example 38

```````````````````````````````` example
&#42; foo

* foo
.
<p>* foo</p>
<ul>
<li>foo</li>
</ul>
````````````````````````````````

## example 39

```````````````````````````````` example
foo&#10;&#10;bar
.
<p>foo

bar</p>
````````````````````````````````

## example 40

```````````````````````````````` example
&#9;foo
.
<p>	foo</p>
````````````````````````````````

## example 41

```````````````````````````````` example
[a](url &quot;tit&quot;)
.
<p>[a](url &quot;tit&quot;)</p>
````````````````````````````````

