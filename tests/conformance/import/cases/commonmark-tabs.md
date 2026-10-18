# CommonMark 0.31.2 spec, section "Tabs"

## example 1

```````````````````````````````` example
	foo	baz		bim
.
<pre><code>foo	baz		bim
</code></pre>
````````````````````````````````

## example 2

```````````````````````````````` example
  	foo	baz		bim
.
<pre><code>foo	baz		bim
</code></pre>
````````````````````````````````

## example 3

```````````````````````````````` example
    a	a
    ὐ	a
.
<pre><code>a	a
ὐ	a
</code></pre>
````````````````````````````````

## example 4

```````````````````````````````` example
  - foo

	bar
.
<ul>
<li>
<p>foo</p>
<p>bar</p>
</li>
</ul>
````````````````````````````````

## example 5

```````````````````````````````` example
- foo

		bar
.
<ul>
<li>
<p>foo</p>
<pre><code>  bar
</code></pre>
</li>
</ul>
````````````````````````````````

## example 6

```````````````````````````````` example
>		foo
.
<blockquote>
<pre><code>  foo
</code></pre>
</blockquote>
````````````````````````````````

## example 7

```````````````````````````````` example
-		foo
.
<ul>
<li>
<pre><code>  foo
</code></pre>
</li>
</ul>
````````````````````````````````

## example 8

```````````````````````````````` example
    foo
	bar
.
<pre><code>foo
bar
</code></pre>
````````````````````````````````

## example 9

```````````````````````````````` example
 - foo
   - bar
	 - baz
.
<ul>
<li>foo
<ul>
<li>bar
<ul>
<li>baz</li>
</ul>
</li>
</ul>
</li>
</ul>
````````````````````````````````

## example 10

```````````````````````````````` example
#	Foo
.
<h1>Foo</h1>
````````````````````````````````

## example 11

```````````````````````````````` example
*	*	*	
.
<hr />
````````````````````````````````

