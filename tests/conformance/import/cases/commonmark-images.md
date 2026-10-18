# CommonMark 0.31.2 spec, section "Images"

## example 572

```````````````````````````````` example
![foo](/url "title")
.
<p><img src="/url" alt="foo" title="title" /></p>
````````````````````````````````

## example 573

```````````````````````````````` example
![foo *bar*]

[foo *bar*]: train.jpg "train & tracks"
.
<p><img src="train.jpg" alt="foo bar" title="train &amp; tracks" /></p>
````````````````````````````````

## example 574

```````````````````````````````` example
![foo ![bar](/url)](/url2)
.
<p><img src="/url2" alt="foo bar" /></p>
````````````````````````````````

## example 575

```````````````````````````````` example
![foo [bar](/url)](/url2)
.
<p><img src="/url2" alt="foo bar" /></p>
````````````````````````````````

## example 576

```````````````````````````````` example
![foo *bar*][]

[foo *bar*]: train.jpg "train & tracks"
.
<p><img src="train.jpg" alt="foo bar" title="train &amp; tracks" /></p>
````````````````````````````````

## example 577

```````````````````````````````` example
![foo *bar*][foobar]

[FOOBAR]: train.jpg "train & tracks"
.
<p><img src="train.jpg" alt="foo bar" title="train &amp; tracks" /></p>
````````````````````````````````

## example 578

```````````````````````````````` example
![foo](train.jpg)
.
<p><img src="train.jpg" alt="foo" /></p>
````````````````````````````````

## example 579

```````````````````````````````` example
My ![foo bar](/path/to/train.jpg  "title"   )
.
<p>My <img src="/path/to/train.jpg" alt="foo bar" title="title" /></p>
````````````````````````````````

## example 580

```````````````````````````````` example
![foo](<url>)
.
<p><img src="url" alt="foo" /></p>
````````````````````````````````

## example 581

```````````````````````````````` example
![](/url)
.
<p><img src="/url" alt="" /></p>
````````````````````````````````

## example 582

```````````````````````````````` example
![foo][bar]

[bar]: /url
.
<p><img src="/url" alt="foo" /></p>
````````````````````````````````

## example 583

```````````````````````````````` example
![foo][bar]

[BAR]: /url
.
<p><img src="/url" alt="foo" /></p>
````````````````````````````````

## example 584

```````````````````````````````` example
![foo][]

[foo]: /url "title"
.
<p><img src="/url" alt="foo" title="title" /></p>
````````````````````````````````

## example 585

```````````````````````````````` example
![*foo* bar][]

[*foo* bar]: /url "title"
.
<p><img src="/url" alt="foo bar" title="title" /></p>
````````````````````````````````

## example 586

```````````````````````````````` example
![Foo][]

[foo]: /url "title"
.
<p><img src="/url" alt="Foo" title="title" /></p>
````````````````````````````````

## example 587

```````````````````````````````` example
![foo] 
[]

[foo]: /url "title"
.
<p><img src="/url" alt="foo" title="title" />
[]</p>
````````````````````````````````

## example 588

```````````````````````````````` example
![foo]

[foo]: /url "title"
.
<p><img src="/url" alt="foo" title="title" /></p>
````````````````````````````````

## example 589

```````````````````````````````` example
![*foo* bar]

[*foo* bar]: /url "title"
.
<p><img src="/url" alt="foo bar" title="title" /></p>
````````````````````````````````

## example 590

```````````````````````````````` example
![[foo]]

[[foo]]: /url "title"
.
<p>![[foo]]</p>
<p>[[foo]]: /url &quot;title&quot;</p>
````````````````````````````````

## example 591

```````````````````````````````` example
![Foo]

[foo]: /url "title"
.
<p><img src="/url" alt="Foo" title="title" /></p>
````````````````````````````````

## example 592

```````````````````````````````` example
!\[foo]

[foo]: /url "title"
.
<p>![foo]</p>
````````````````````````````````

## example 593

```````````````````````````````` example
\![foo]

[foo]: /url "title"
.
<p>!<a href="/url" title="title">foo</a></p>
````````````````````````````````

