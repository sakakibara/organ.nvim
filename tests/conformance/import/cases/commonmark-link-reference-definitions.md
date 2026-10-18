# CommonMark 0.31.2 spec, section "Link reference definitions"

## example 192

```````````````````````````````` example
[foo]: /url "title"

[foo]
.
<p><a href="/url" title="title">foo</a></p>
````````````````````````````````

## example 193

```````````````````````````````` example
   [foo]: 
      /url  
           'the title'  

[foo]
.
<p><a href="/url" title="the title">foo</a></p>
````````````````````````````````

## example 194

```````````````````````````````` example
[Foo*bar\]]:my_(url) 'title (with parens)'

[Foo*bar\]]
.
<p><a href="my_(url)" title="title (with parens)">Foo*bar]</a></p>
````````````````````````````````

## example 195

```````````````````````````````` example
[Foo bar]:
<my url>
'title'

[Foo bar]
.
<p><a href="my%20url" title="title">Foo bar</a></p>
````````````````````````````````

## example 196

```````````````````````````````` example
[foo]: /url '
title
line1
line2
'

[foo]
.
<p><a href="/url" title="
title
line1
line2
">foo</a></p>
````````````````````````````````

## example 197

```````````````````````````````` example
[foo]: /url 'title

with blank line'

[foo]
.
<p>[foo]: /url 'title</p>
<p>with blank line'</p>
<p>[foo]</p>
````````````````````````````````

## example 198

```````````````````````````````` example
[foo]:
/url

[foo]
.
<p><a href="/url">foo</a></p>
````````````````````````````````

## example 199

```````````````````````````````` example
[foo]:

[foo]
.
<p>[foo]:</p>
<p>[foo]</p>
````````````````````````````````

## example 200

```````````````````````````````` example
[foo]: <>

[foo]
.
<p><a href="">foo</a></p>
````````````````````````````````

## example 201

```````````````````````````````` example
[foo]: <bar>(baz)

[foo]
.
<p>[foo]: <bar>(baz)</p>
<p>[foo]</p>
````````````````````````````````

## example 202

```````````````````````````````` example
[foo]: /url\bar\*baz "foo\"bar\baz"

[foo]
.
<p><a href="/url%5Cbar*baz" title="foo&quot;bar\baz">foo</a></p>
````````````````````````````````

## example 203

```````````````````````````````` example
[foo]

[foo]: url
.
<p><a href="url">foo</a></p>
````````````````````````````````

## example 204

```````````````````````````````` example
[foo]

[foo]: first
[foo]: second
.
<p><a href="first">foo</a></p>
````````````````````````````````

## example 205

```````````````````````````````` example
[FOO]: /url

[Foo]
.
<p><a href="/url">Foo</a></p>
````````````````````````````````

## example 206

```````````````````````````````` example
[ΑΓΩ]: /φου

[αγω]
.
<p><a href="/%CF%86%CE%BF%CF%85">αγω</a></p>
````````````````````````````````

## example 207

```````````````````````````````` example
[foo]: /url
.
````````````````````````````````

## example 208

```````````````````````````````` example
[
foo
]: /url
bar
.
<p>bar</p>
````````````````````````````````

## example 209

```````````````````````````````` example
[foo]: /url "title" ok
.
<p>[foo]: /url &quot;title&quot; ok</p>
````````````````````````````````

## example 210

```````````````````````````````` example
[foo]: /url
"title" ok
.
<p>&quot;title&quot; ok</p>
````````````````````````````````

## example 211

```````````````````````````````` example
    [foo]: /url "title"

[foo]
.
<pre><code>[foo]: /url &quot;title&quot;
</code></pre>
<p>[foo]</p>
````````````````````````````````

## example 212

```````````````````````````````` example
```
[foo]: /url
```

[foo]
.
<pre><code>[foo]: /url
</code></pre>
<p>[foo]</p>
````````````````````````````````

## example 213

```````````````````````````````` example
Foo
[bar]: /baz

[bar]
.
<p>Foo
[bar]: /baz</p>
<p>[bar]</p>
````````````````````````````````

## example 214

```````````````````````````````` example
# [Foo]
[foo]: /url
> bar
.
<h1><a href="/url">Foo</a></h1>
<blockquote>
<p>bar</p>
</blockquote>
````````````````````````````````

## example 215

```````````````````````````````` example
[foo]: /url
bar
===
[foo]
.
<h1>bar</h1>
<p><a href="/url">foo</a></p>
````````````````````````````````

## example 216

```````````````````````````````` example
[foo]: /url
===
[foo]
.
<p>===
<a href="/url">foo</a></p>
````````````````````````````````

## example 217

```````````````````````````````` example
[foo]: /foo-url "foo"
[bar]: /bar-url
  "bar"
[baz]: /baz-url

[foo],
[bar],
[baz]
.
<p><a href="/foo-url" title="foo">foo</a>,
<a href="/bar-url" title="bar">bar</a>,
<a href="/baz-url">baz</a></p>
````````````````````````````````

## example 218

```````````````````````````````` example
[foo]

> [foo]: /url
.
<p><a href="/url">foo</a></p>
<blockquote>
</blockquote>
````````````````````````````````

