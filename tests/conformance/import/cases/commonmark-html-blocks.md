# CommonMark 0.31.2 spec, section "HTML blocks"

## example 148

```````````````````````````````` example
<table><tr><td>
<pre>
**Hello**,

_world_.
</pre>
</td></tr></table>
.
<table><tr><td>
<pre>
**Hello**,
<p><em>world</em>.
</pre></p>
</td></tr></table>
````````````````````````````````

## example 149

```````````````````````````````` example
<table>
  <tr>
    <td>
           hi
    </td>
  </tr>
</table>

okay.
.
<table>
  <tr>
    <td>
           hi
    </td>
  </tr>
</table>
<p>okay.</p>
````````````````````````````````

## example 150

```````````````````````````````` example
 <div>
  *hello*
         <foo><a>
.
 <div>
  *hello*
         <foo><a>
````````````````````````````````

## example 151

```````````````````````````````` example
</div>
*foo*
.
</div>
*foo*
````````````````````````````````

## example 152

```````````````````````````````` example
<DIV CLASS="foo">

*Markdown*

</DIV>
.
<DIV CLASS="foo">
<p><em>Markdown</em></p>
</DIV>
````````````````````````````````

## example 153

```````````````````````````````` example
<div id="foo"
  class="bar">
</div>
.
<div id="foo"
  class="bar">
</div>
````````````````````````````````

## example 154

```````````````````````````````` example
<div id="foo" class="bar
  baz">
</div>
.
<div id="foo" class="bar
  baz">
</div>
````````````````````````````````

## example 155

```````````````````````````````` example
<div>
*foo*

*bar*
.
<div>
*foo*
<p><em>bar</em></p>
````````````````````````````````

## example 156

```````````````````````````````` example
<div id="foo"
*hi*
.
<div id="foo"
*hi*
````````````````````````````````

## example 157

```````````````````````````````` example
<div class
foo
.
<div class
foo
````````````````````````````````

## example 158

```````````````````````````````` example
<div *???-&&&-<---
*foo*
.
<div *???-&&&-<---
*foo*
````````````````````````````````

## example 159

```````````````````````````````` example
<div><a href="bar">*foo*</a></div>
.
<div><a href="bar">*foo*</a></div>
````````````````````````````````

## example 160

```````````````````````````````` example
<table><tr><td>
foo
</td></tr></table>
.
<table><tr><td>
foo
</td></tr></table>
````````````````````````````````

## example 161

```````````````````````````````` example
<div></div>
``` c
int x = 33;
```
.
<div></div>
``` c
int x = 33;
```
````````````````````````````````

## example 162

```````````````````````````````` example
<a href="foo">
*bar*
</a>
.
<a href="foo">
*bar*
</a>
````````````````````````````````

## example 163

```````````````````````````````` example
<Warning>
*bar*
</Warning>
.
<Warning>
*bar*
</Warning>
````````````````````````````````

## example 164

```````````````````````````````` example
<i class="foo">
*bar*
</i>
.
<i class="foo">
*bar*
</i>
````````````````````````````````

## example 165

```````````````````````````````` example
</ins>
*bar*
.
</ins>
*bar*
````````````````````````````````

## example 166

```````````````````````````````` example
<del>
*foo*
</del>
.
<del>
*foo*
</del>
````````````````````````````````

## example 167

```````````````````````````````` example
<del>

*foo*

</del>
.
<del>
<p><em>foo</em></p>
</del>
````````````````````````````````

## example 168

```````````````````````````````` example
<del>*foo*</del>
.
<p><del><em>foo</em></del></p>
````````````````````````````````

## example 169

```````````````````````````````` example
<pre language="haskell"><code>
import Text.HTML.TagSoup

main :: IO ()
main = print $ parseTags tags
</code></pre>
okay
.
<pre language="haskell"><code>
import Text.HTML.TagSoup

main :: IO ()
main = print $ parseTags tags
</code></pre>
<p>okay</p>
````````````````````````````````

## example 170

```````````````````````````````` example
<script type="text/javascript">
// JavaScript example

document.getElementById("demo").innerHTML = "Hello JavaScript!";
</script>
okay
.
<script type="text/javascript">
// JavaScript example

document.getElementById("demo").innerHTML = "Hello JavaScript!";
</script>
<p>okay</p>
````````````````````````````````

## example 171

```````````````````````````````` example
<textarea>

*foo*

_bar_

</textarea>
.
<textarea>

*foo*

_bar_

</textarea>
````````````````````````````````

## example 172

```````````````````````````````` example
<style
  type="text/css">
h1 {color:red;}

p {color:blue;}
</style>
okay
.
<style
  type="text/css">
h1 {color:red;}

p {color:blue;}
</style>
<p>okay</p>
````````````````````````````````

## example 173

```````````````````````````````` example
<style
  type="text/css">

foo
.
<style
  type="text/css">

foo
````````````````````````````````

## example 174

```````````````````````````````` example
> <div>
> foo

bar
.
<blockquote>
<div>
foo
</blockquote>
<p>bar</p>
````````````````````````````````

## example 175

```````````````````````````````` example
- <div>
- foo
.
<ul>
<li>
<div>
</li>
<li>foo</li>
</ul>
````````````````````````````````

## example 176

```````````````````````````````` example
<style>p{color:red;}</style>
*foo*
.
<style>p{color:red;}</style>
<p><em>foo</em></p>
````````````````````````````````

## example 177

```````````````````````````````` example
<!-- foo -->*bar*
*baz*
.
<!-- foo -->*bar*
<p><em>baz</em></p>
````````````````````````````````

## example 178

```````````````````````````````` example
<script>
foo
</script>1. *bar*
.
<script>
foo
</script>1. *bar*
````````````````````````````````

## example 179

```````````````````````````````` example
<!-- Foo

bar
   baz -->
okay
.
<!-- Foo

bar
   baz -->
<p>okay</p>
````````````````````````````````

## example 180

```````````````````````````````` example
<?php

  echo '>';

?>
okay
.
<?php

  echo '>';

?>
<p>okay</p>
````````````````````````````````

## example 181

```````````````````````````````` example
<!DOCTYPE html>
.
<!DOCTYPE html>
````````````````````````````````

## example 182

```````````````````````````````` example
<![CDATA[
function matchwo(a,b)
{
  if (a < b && a < 0) then {
    return 1;

  } else {

    return 0;
  }
}
]]>
okay
.
<![CDATA[
function matchwo(a,b)
{
  if (a < b && a < 0) then {
    return 1;

  } else {

    return 0;
  }
}
]]>
<p>okay</p>
````````````````````````````````

## example 183

```````````````````````````````` example
  <!-- foo -->

    <!-- foo -->
.
  <!-- foo -->
<pre><code>&lt;!-- foo --&gt;
</code></pre>
````````````````````````````````

## example 184

```````````````````````````````` example
  <div>

    <div>
.
  <div>
<pre><code>&lt;div&gt;
</code></pre>
````````````````````````````````

## example 185

```````````````````````````````` example
Foo
<div>
bar
</div>
.
<p>Foo</p>
<div>
bar
</div>
````````````````````````````````

## example 186

```````````````````````````````` example
<div>
bar
</div>
*foo*
.
<div>
bar
</div>
*foo*
````````````````````````````````

## example 187

```````````````````````````````` example
Foo
<a href="bar">
baz
.
<p>Foo
<a href="bar">
baz</p>
````````````````````````````````

## example 188

```````````````````````````````` example
<div>

*Emphasized* text.

</div>
.
<div>
<p><em>Emphasized</em> text.</p>
</div>
````````````````````````````````

## example 189

```````````````````````````````` example
<div>
*Emphasized* text.
</div>
.
<div>
*Emphasized* text.
</div>
````````````````````````````````

## example 190

```````````````````````````````` example
<table>

<tr>

<td>
Hi
</td>

</tr>

</table>
.
<table>
<tr>
<td>
Hi
</td>
</tr>
</table>
````````````````````````````````

## example 191

```````````````````````````````` example
<table>

  <tr>

    <td>
      Hi
    </td>

  </tr>

</table>
.
<table>
  <tr>
<pre><code>&lt;td&gt;
  Hi
&lt;/td&gt;
</code></pre>
  </tr>
</table>
````````````````````````````````

