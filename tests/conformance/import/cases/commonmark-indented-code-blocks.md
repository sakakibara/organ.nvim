# CommonMark 0.31.2 spec, section "Indented code blocks"

## example 107

```````````````````````````````` example
    a simple
      indented code block
.
<pre><code>a simple
  indented code block
</code></pre>
````````````````````````````````

## example 108

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

## example 109

```````````````````````````````` example
1.  foo

    - bar
.
<ol>
<li>
<p>foo</p>
<ul>
<li>bar</li>
</ul>
</li>
</ol>
````````````````````````````````

## example 110

```````````````````````````````` example
    <a/>
    *hi*

    - one
.
<pre><code>&lt;a/&gt;
*hi*

- one
</code></pre>
````````````````````````````````

## example 111

```````````````````````````````` example
    chunk1

    chunk2
  
 
 
    chunk3
.
<pre><code>chunk1

chunk2



chunk3
</code></pre>
````````````````````````````````

## example 112

```````````````````````````````` example
    chunk1
      
      chunk2
.
<pre><code>chunk1
  
  chunk2
</code></pre>
````````````````````````````````

## example 113

```````````````````````````````` example
Foo
    bar

.
<p>Foo
bar</p>
````````````````````````````````

## example 114

```````````````````````````````` example
    foo
bar
.
<pre><code>foo
</code></pre>
<p>bar</p>
````````````````````````````````

## example 115

```````````````````````````````` example
# Heading
    foo
Heading
------
    foo
----
.
<h1>Heading</h1>
<pre><code>foo
</code></pre>
<h2>Heading</h2>
<pre><code>foo
</code></pre>
<hr />
````````````````````````````````

## example 116

```````````````````````````````` example
        foo
    bar
.
<pre><code>    foo
bar
</code></pre>
````````````````````````````````

## example 117

```````````````````````````````` example

    
    foo
    

.
<pre><code>foo
</code></pre>
````````````````````````````````

## example 118

```````````````````````````````` example
    foo  
.
<pre><code>foo  
</code></pre>
````````````````````````````````

