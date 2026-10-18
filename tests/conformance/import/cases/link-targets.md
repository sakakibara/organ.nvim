# Link targets, titles and descriptions (expected HTML: cmark-gfm form)

## link_title

```````````````````````````````` example
[a](http://x.com "T")
.
<p><a href="http://x.com" title="T">a</a></p>
````````````````````````````````

## link_relative

```````````````````````````````` example
[r](docs/file.md) [h](#sec) [m](mailto:a@b.c) [d](./x.org)
.
<p><a href="docs/file.md">r</a> <a href="#sec">h</a> <a href="mailto:a@b.c">m</a> <a href="./x.org">d</a></p>
````````````````````````````````

## link_angle_space

```````````````````````````````` example
[s](<a b.html>)
.
<p><a href="a%20b.html">s</a></p>
````````````````````````````````

## link_brackets_desc

```````````````````````````````` example
[a [b] c](http://x.com)
.
<p><a href="http://x.com">a [b] c</a></p>
````````````````````````````````

## link_target_paren_coderef

```````````````````````````````` example
[x](a(b))
.
<p><a href="a(b)">x</a></p>
````````````````````````````````

## link_target_star_heading

```````````````````````````````` example
[x](*foo)
.
<p><a href="*foo">x</a></p>
````````````````````````````````

## link_target_hash_custom

```````````````````````````````` example
[x](#my-id)
.
<p><a href="#my-id">x</a></p>
````````````````````````````````

## link_id

```````````````````````````````` example
[x](id:123)
.
<p><a href="id:123">x</a></p>
````````````````````````````````

## percent_in_url

```````````````````````````````` example
[x](http://e.com/a%20b)
.
<p><a href="http://e.com/a%20b">x</a></p>
````````````````````````````````

## emph_cross_link

```````````````````````````````` example
*a [b](http://x) c*
.
<p><em>a <a href="http://x">b</a> c</em></p>
````````````````````````````````

