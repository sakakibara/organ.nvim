# CommonMark 0.31.2 spec, section "Autolinks"

## example 594

```````````````````````````````` example
<http://foo.bar.baz>
.
<p><a href="http://foo.bar.baz">http://foo.bar.baz</a></p>
````````````````````````````````

## example 595

```````````````````````````````` example
<https://foo.bar.baz/test?q=hello&id=22&boolean>
.
<p><a href="https://foo.bar.baz/test?q=hello&amp;id=22&amp;boolean">https://foo.bar.baz/test?q=hello&amp;id=22&amp;boolean</a></p>
````````````````````````````````

## example 596

```````````````````````````````` example
<irc://foo.bar:2233/baz>
.
<p><a href="irc://foo.bar:2233/baz">irc://foo.bar:2233/baz</a></p>
````````````````````````````````

## example 597

```````````````````````````````` example
<MAILTO:FOO@BAR.BAZ>
.
<p><a href="MAILTO:FOO@BAR.BAZ">MAILTO:FOO@BAR.BAZ</a></p>
````````````````````````````````

## example 598

```````````````````````````````` example
<a+b+c:d>
.
<p><a href="a+b+c:d">a+b+c:d</a></p>
````````````````````````````````

## example 599

```````````````````````````````` example
<made-up-scheme://foo,bar>
.
<p><a href="made-up-scheme://foo,bar">made-up-scheme://foo,bar</a></p>
````````````````````````````````

## example 600

```````````````````````````````` example
<https://../>
.
<p><a href="https://../">https://../</a></p>
````````````````````````````````

## example 601

```````````````````````````````` example
<localhost:5001/foo>
.
<p><a href="localhost:5001/foo">localhost:5001/foo</a></p>
````````````````````````````````

## example 602

```````````````````````````````` example
<https://foo.bar/baz bim>
.
<p>&lt;https://foo.bar/baz bim&gt;</p>
````````````````````````````````

## example 603

```````````````````````````````` example
<https://example.com/\[\>
.
<p><a href="https://example.com/%5C%5B%5C">https://example.com/\[\</a></p>
````````````````````````````````

## example 604

```````````````````````````````` example
<foo@bar.example.com>
.
<p><a href="mailto:foo@bar.example.com">foo@bar.example.com</a></p>
````````````````````````````````

## example 605

```````````````````````````````` example
<foo+special@Bar.baz-bar0.com>
.
<p><a href="mailto:foo+special@Bar.baz-bar0.com">foo+special@Bar.baz-bar0.com</a></p>
````````````````````````````````

## example 606

```````````````````````````````` example
<foo\+@bar.example.com>
.
<p>&lt;foo+@bar.example.com&gt;</p>
````````````````````````````````

## example 607

```````````````````````````````` example
<>
.
<p>&lt;&gt;</p>
````````````````````````````````

## example 608

```````````````````````````````` example
< https://foo.bar >
.
<p>&lt; https://foo.bar &gt;</p>
````````````````````````````````

## example 609

```````````````````````````````` example
<m:abc>
.
<p>&lt;m:abc&gt;</p>
````````````````````````````````

## example 610

```````````````````````````````` example
<foo.bar.baz>
.
<p>&lt;foo.bar.baz&gt;</p>
````````````````````````````````

## example 611

```````````````````````````````` example
https://example.com
.
<p>https://example.com</p>
````````````````````````````````

## example 612

```````````````````````````````` example
foo@bar.example.com
.
<p>foo@bar.example.com</p>
````````````````````````````````

