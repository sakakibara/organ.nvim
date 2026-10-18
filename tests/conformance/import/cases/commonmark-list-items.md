# CommonMark 0.31.2 spec, section "List items"

## example 253

```````````````````````````````` example
A paragraph
with two lines.

    indented code

> A block quote.
.
<p>A paragraph
with two lines.</p>
<pre><code>indented code
</code></pre>
<blockquote>
<p>A block quote.</p>
</blockquote>
````````````````````````````````

## example 254

```````````````````````````````` example
1.  A paragraph
    with two lines.

        indented code

    > A block quote.
.
<ol>
<li>
<p>A paragraph
with two lines.</p>
<pre><code>indented code
</code></pre>
<blockquote>
<p>A block quote.</p>
</blockquote>
</li>
</ol>
````````````````````````````````

## example 255

```````````````````````````````` example
- one

 two
.
<ul>
<li>one</li>
</ul>
<p>two</p>
````````````````````````````````

## example 256

```````````````````````````````` example
- one

  two
.
<ul>
<li>
<p>one</p>
<p>two</p>
</li>
</ul>
````````````````````````````````

## example 257

```````````````````````````````` example
 -    one

     two
.
<ul>
<li>one</li>
</ul>
<pre><code> two
</code></pre>
````````````````````````````````

## example 258

```````````````````````````````` example
 -    one

      two
.
<ul>
<li>
<p>one</p>
<p>two</p>
</li>
</ul>
````````````````````````````````

## example 259

```````````````````````````````` example
   > > 1.  one
>>
>>     two
.
<blockquote>
<blockquote>
<ol>
<li>
<p>one</p>
<p>two</p>
</li>
</ol>
</blockquote>
</blockquote>
````````````````````````````````

## example 260

```````````````````````````````` example
>>- one
>>
  >  > two
.
<blockquote>
<blockquote>
<ul>
<li>one</li>
</ul>
<p>two</p>
</blockquote>
</blockquote>
````````````````````````````````

## example 261

```````````````````````````````` example
-one

2.two
.
<p>-one</p>
<p>2.two</p>
````````````````````````````````

## example 262

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

## example 263

```````````````````````````````` example
1.  foo

    ```
    bar
    ```

    baz

    > bam
.
<ol>
<li>
<p>foo</p>
<pre><code>bar
</code></pre>
<p>baz</p>
<blockquote>
<p>bam</p>
</blockquote>
</li>
</ol>
````````````````````````````````

## example 264

```````````````````````````````` example
- Foo

      bar


      baz
.
<ul>
<li>
<p>Foo</p>
<pre><code>bar


baz
</code></pre>
</li>
</ul>
````````````````````````````````

## example 265

```````````````````````````````` example
123456789. ok
.
<ol start="123456789">
<li>ok</li>
</ol>
````````````````````````````````

## example 266

```````````````````````````````` example
1234567890. not ok
.
<p>1234567890. not ok</p>
````````````````````````````````

## example 267

```````````````````````````````` example
0. ok
.
<ol start="0">
<li>ok</li>
</ol>
````````````````````````````````

## example 268

```````````````````````````````` example
003. ok
.
<ol start="3">
<li>ok</li>
</ol>
````````````````````````````````

## example 269

```````````````````````````````` example
-1. not ok
.
<p>-1. not ok</p>
````````````````````````````````

## example 270

```````````````````````````````` example
- foo

      bar
.
<ul>
<li>
<p>foo</p>
<pre><code>bar
</code></pre>
</li>
</ul>
````````````````````````````````

## example 271

```````````````````````````````` example
  10.  foo

           bar
.
<ol start="10">
<li>
<p>foo</p>
<pre><code>bar
</code></pre>
</li>
</ol>
````````````````````````````````

## example 272

```````````````````````````````` example
    indented code

paragraph

    more code
.
<pre><code>indented code
</code></pre>
<p>paragraph</p>
<pre><code>more code
</code></pre>
````````````````````````````````

## example 273

```````````````````````````````` example
1.     indented code

   paragraph

       more code
.
<ol>
<li>
<pre><code>indented code
</code></pre>
<p>paragraph</p>
<pre><code>more code
</code></pre>
</li>
</ol>
````````````````````````````````

## example 274

```````````````````````````````` example
1.      indented code

   paragraph

       more code
.
<ol>
<li>
<pre><code> indented code
</code></pre>
<p>paragraph</p>
<pre><code>more code
</code></pre>
</li>
</ol>
````````````````````````````````

## example 275

```````````````````````````````` example
   foo

bar
.
<p>foo</p>
<p>bar</p>
````````````````````````````````

## example 276

```````````````````````````````` example
-    foo

  bar
.
<ul>
<li>foo</li>
</ul>
<p>bar</p>
````````````````````````````````

## example 277

```````````````````````````````` example
-  foo

   bar
.
<ul>
<li>
<p>foo</p>
<p>bar</p>
</li>
</ul>
````````````````````````````````

## example 278

```````````````````````````````` example
-
  foo
-
  ```
  bar
  ```
-
      baz
.
<ul>
<li>foo</li>
<li>
<pre><code>bar
</code></pre>
</li>
<li>
<pre><code>baz
</code></pre>
</li>
</ul>
````````````````````````````````

## example 279

```````````````````````````````` example
-   
  foo
.
<ul>
<li>foo</li>
</ul>
````````````````````````````````

## example 280

```````````````````````````````` example
-

  foo
.
<ul>
<li></li>
</ul>
<p>foo</p>
````````````````````````````````

## example 281

```````````````````````````````` example
- foo
-
- bar
.
<ul>
<li>foo</li>
<li></li>
<li>bar</li>
</ul>
````````````````````````````````

## example 282

```````````````````````````````` example
- foo
-   
- bar
.
<ul>
<li>foo</li>
<li></li>
<li>bar</li>
</ul>
````````````````````````````````

## example 283

```````````````````````````````` example
1. foo
2.
3. bar
.
<ol>
<li>foo</li>
<li></li>
<li>bar</li>
</ol>
````````````````````````````````

## example 284

```````````````````````````````` example
*
.
<ul>
<li></li>
</ul>
````````````````````````````````

## example 285

```````````````````````````````` example
foo
*

foo
1.
.
<p>foo
*</p>
<p>foo
1.</p>
````````````````````````````````

## example 286

```````````````````````````````` example
 1.  A paragraph
     with two lines.

         indented code

     > A block quote.
.
<ol>
<li>
<p>A paragraph
with two lines.</p>
<pre><code>indented code
</code></pre>
<blockquote>
<p>A block quote.</p>
</blockquote>
</li>
</ol>
````````````````````````````````

## example 287

```````````````````````````````` example
  1.  A paragraph
      with two lines.

          indented code

      > A block quote.
.
<ol>
<li>
<p>A paragraph
with two lines.</p>
<pre><code>indented code
</code></pre>
<blockquote>
<p>A block quote.</p>
</blockquote>
</li>
</ol>
````````````````````````````````

## example 288

```````````````````````````````` example
   1.  A paragraph
       with two lines.

           indented code

       > A block quote.
.
<ol>
<li>
<p>A paragraph
with two lines.</p>
<pre><code>indented code
</code></pre>
<blockquote>
<p>A block quote.</p>
</blockquote>
</li>
</ol>
````````````````````````````````

## example 289

```````````````````````````````` example
    1.  A paragraph
        with two lines.

            indented code

        > A block quote.
.
<pre><code>1.  A paragraph
    with two lines.

        indented code

    &gt; A block quote.
</code></pre>
````````````````````````````````

## example 290

```````````````````````````````` example
  1.  A paragraph
with two lines.

          indented code

      > A block quote.
.
<ol>
<li>
<p>A paragraph
with two lines.</p>
<pre><code>indented code
</code></pre>
<blockquote>
<p>A block quote.</p>
</blockquote>
</li>
</ol>
````````````````````````````````

## example 291

```````````````````````````````` example
  1.  A paragraph
    with two lines.
.
<ol>
<li>A paragraph
with two lines.</li>
</ol>
````````````````````````````````

## example 292

```````````````````````````````` example
> 1. > Blockquote
continued here.
.
<blockquote>
<ol>
<li>
<blockquote>
<p>Blockquote
continued here.</p>
</blockquote>
</li>
</ol>
</blockquote>
````````````````````````````````

## example 293

```````````````````````````````` example
> 1. > Blockquote
> continued here.
.
<blockquote>
<ol>
<li>
<blockquote>
<p>Blockquote
continued here.</p>
</blockquote>
</li>
</ol>
</blockquote>
````````````````````````````````

## example 294

```````````````````````````````` example
- foo
  - bar
    - baz
      - boo
.
<ul>
<li>foo
<ul>
<li>bar
<ul>
<li>baz
<ul>
<li>boo</li>
</ul>
</li>
</ul>
</li>
</ul>
</li>
</ul>
````````````````````````````````

## example 295

```````````````````````````````` example
- foo
 - bar
  - baz
   - boo
.
<ul>
<li>foo</li>
<li>bar</li>
<li>baz</li>
<li>boo</li>
</ul>
````````````````````````````````

## example 296

```````````````````````````````` example
10) foo
    - bar
.
<ol start="10">
<li>foo
<ul>
<li>bar</li>
</ul>
</li>
</ol>
````````````````````````````````

## example 297

```````````````````````````````` example
10) foo
   - bar
.
<ol start="10">
<li>foo</li>
</ol>
<ul>
<li>bar</li>
</ul>
````````````````````````````````

## example 298

```````````````````````````````` example
- - foo
.
<ul>
<li>
<ul>
<li>foo</li>
</ul>
</li>
</ul>
````````````````````````````````

## example 299

```````````````````````````````` example
1. - 2. foo
.
<ol>
<li>
<ul>
<li>
<ol start="2">
<li>foo</li>
</ol>
</li>
</ul>
</li>
</ol>
````````````````````````````````

## example 300

```````````````````````````````` example
- # Foo
- Bar
  ---
  baz
.
<ul>
<li>
<h1>Foo</h1>
</li>
<li>
<h2>Bar</h2>
baz</li>
</ul>
````````````````````````````````

