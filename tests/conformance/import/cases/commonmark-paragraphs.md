# CommonMark 0.31.2 spec, section "Paragraphs"

## example 219

```````````````````````````````` example
aaa

bbb
.
<p>aaa</p>
<p>bbb</p>
````````````````````````````````

## example 220

```````````````````````````````` example
aaa
bbb

ccc
ddd
.
<p>aaa
bbb</p>
<p>ccc
ddd</p>
````````````````````````````````

## example 221

```````````````````````````````` example
aaa


bbb
.
<p>aaa</p>
<p>bbb</p>
````````````````````````````````

## example 222

```````````````````````````````` example
  aaa
 bbb
.
<p>aaa
bbb</p>
````````````````````````````````

## example 223

```````````````````````````````` example
aaa
             bbb
                                       ccc
.
<p>aaa
bbb
ccc</p>
````````````````````````````````

## example 224

```````````````````````````````` example
   aaa
bbb
.
<p>aaa
bbb</p>
````````````````````````````````

## example 225

```````````````````````````````` example
    aaa
bbb
.
<pre><code>aaa
</code></pre>
<p>bbb</p>
````````````````````````````````

## example 226

```````````````````````````````` example
aaa     
bbb     
.
<p>aaa<br />
bbb</p>
````````````````````````````````

