# CommonMark 0.31.2 spec, section "Raw HTML"

## example 613

```````````````````````````````` example
<a><bab><c2c>
.
<p><a><bab><c2c></p>
````````````````````````````````

## example 614

```````````````````````````````` example
<a/><b2/>
.
<p><a/><b2/></p>
````````````````````````````````

## example 615

```````````````````````````````` example
<a  /><b2
data="foo" >
.
<p><a  /><b2
data="foo" ></p>
````````````````````````````````

## example 616

```````````````````````````````` example
<a foo="bar" bam = 'baz <em>"</em>'
_boolean zoop:33=zoop:33 />
.
<p><a foo="bar" bam = 'baz <em>"</em>'
_boolean zoop:33=zoop:33 /></p>
````````````````````````````````

## example 617

```````````````````````````````` example
Foo <responsive-image src="foo.jpg" />
.
<p>Foo <responsive-image src="foo.jpg" /></p>
````````````````````````````````

## example 618

```````````````````````````````` example
<33> <__>
.
<p>&lt;33&gt; &lt;__&gt;</p>
````````````````````````````````

## example 619

```````````````````````````````` example
<a h*#ref="hi">
.
<p>&lt;a h*#ref=&quot;hi&quot;&gt;</p>
````````````````````````````````

## example 620

```````````````````````````````` example
<a href="hi'> <a href=hi'>
.
<p>&lt;a href=&quot;hi'&gt; &lt;a href=hi'&gt;</p>
````````````````````````````````

## example 621

```````````````````````````````` example
< a><
foo><bar/ >
<foo bar=baz
bim!bop />
.
<p>&lt; a&gt;&lt;
foo&gt;&lt;bar/ &gt;
&lt;foo bar=baz
bim!bop /&gt;</p>
````````````````````````````````

## example 622

```````````````````````````````` example
<a href='bar'title=title>
.
<p>&lt;a href='bar'title=title&gt;</p>
````````````````````````````````

## example 623

```````````````````````````````` example
</a></foo >
.
<p></a></foo ></p>
````````````````````````````````

## example 624

```````````````````````````````` example
</a href="foo">
.
<p>&lt;/a href=&quot;foo&quot;&gt;</p>
````````````````````````````````

## example 625

```````````````````````````````` example
foo <!-- this is a --
comment - with hyphens -->
.
<p>foo <!-- this is a --
comment - with hyphens --></p>
````````````````````````````````

## example 626

```````````````````````````````` example
foo <!--> foo -->

foo <!---> foo -->
.
<p>foo <!--> foo --&gt;</p>
<p>foo <!---> foo --&gt;</p>
````````````````````````````````

## example 627

```````````````````````````````` example
foo <?php echo $a; ?>
.
<p>foo <?php echo $a; ?></p>
````````````````````````````````

## example 628

```````````````````````````````` example
foo <!ELEMENT br EMPTY>
.
<p>foo <!ELEMENT br EMPTY></p>
````````````````````````````````

## example 629

```````````````````````````````` example
foo <![CDATA[>&<]]>
.
<p>foo <![CDATA[>&<]]></p>
````````````````````````````````

## example 630

```````````````````````````````` example
foo <a href="&ouml;">
.
<p>foo <a href="&ouml;"></p>
````````````````````````````````

## example 631

```````````````````````````````` example
foo <a href="\*">
.
<p>foo <a href="\*"></p>
````````````````````````````````

## example 632

```````````````````````````````` example
<a href="\"">
.
<p>&lt;a href=&quot;&quot;&quot;&gt;</p>
````````````````````````````````

