# CommonMark 0.31.2 spec, section "Backslash escapes"

## example 12

```````````````````````````````` example
\!\"\#\$\%\&\'\(\)\*\+\,\-\.\/\:\;\<\=\>\?\@\[\\\]\^\_\`\{\|\}\~
.
<p>!&quot;#$%&amp;'()*+,-./:;&lt;=&gt;?@[\]^_`{|}~</p>
````````````````````````````````

## example 13

```````````````````````````````` example
\	\A\a\ \3\φ\«
.
<p>\	\A\a\ \3\φ\«</p>
````````````````````````````````

## example 14

```````````````````````````````` example
\*not emphasized*
\<br/> not a tag
\[not a link](/foo)
\`not code`
1\. not a list
\* not a list
\# not a heading
\[foo]: /url "not a reference"
\&ouml; not a character entity
.
<p>*not emphasized*
&lt;br/&gt; not a tag
[not a link](/foo)
`not code`
1. not a list
* not a list
# not a heading
[foo]: /url &quot;not a reference&quot;
&amp;ouml; not a character entity</p>
````````````````````````````````

## example 15

```````````````````````````````` example
\\*emphasis*
.
<p>\<em>emphasis</em></p>
````````````````````````````````

## example 16

```````````````````````````````` example
foo\
bar
.
<p>foo<br />
bar</p>
````````````````````````````````

## example 17

```````````````````````````````` example
`` \[\` ``
.
<p><code>\[\`</code></p>
````````````````````````````````

## example 18

```````````````````````````````` example
    \[\]
.
<pre><code>\[\]
</code></pre>
````````````````````````````````

## example 19

```````````````````````````````` example
~~~
\[\]
~~~
.
<pre><code>\[\]
</code></pre>
````````````````````````````````

## example 20

```````````````````````````````` example
<https://example.com?find=\*>
.
<p><a href="https://example.com?find=%5C*">https://example.com?find=\*</a></p>
````````````````````````````````

## example 21

```````````````````````````````` example
<a href="/bar\/)">
.
<a href="/bar\/)">
````````````````````````````````

## example 22

```````````````````````````````` example
[foo](/bar\* "ti\*tle")
.
<p><a href="/bar*" title="ti*tle">foo</a></p>
````````````````````````````````

## example 23

```````````````````````````````` example
[foo]

[foo]: /bar\* "ti\*tle"
.
<p><a href="/bar*" title="ti*tle">foo</a></p>
````````````````````````````````

## example 24

```````````````````````````````` example
``` foo\+bar
foo
```
.
<pre><code class="language-foo+bar">foo
</code></pre>
````````````````````````````````

