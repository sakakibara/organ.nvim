# Nested block quotes (expected HTML: cmark-gfm form)

## nested_quote_list

```````````````````````````````` example
> - a
>   > q
> - b
.
<blockquote>
<ul>
<li>a
<blockquote>
<p>q</p>
</blockquote>
</li>
<li>b</li>
</ul>
</blockquote>
````````````````````````````````

## quote_nested2

```````````````````````````````` example
> a
>
> > b
>
> c
.
<blockquote>
<p>a</p>
<blockquote>
<p>b</p>
</blockquote>
<p>c</p>
</blockquote>
````````````````````````````````

