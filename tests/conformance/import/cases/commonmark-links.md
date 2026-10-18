# CommonMark 0.31.2 spec, section "Links"

## example 482

```````````````````````````````` example
[link](/uri "title")
.
<p><a href="/uri" title="title">link</a></p>
````````````````````````````````

## example 483

```````````````````````````````` example
[link](/uri)
.
<p><a href="/uri">link</a></p>
````````````````````````````````

## example 484

```````````````````````````````` example
[](./target.md)
.
<p><a href="./target.md"></a></p>
````````````````````````````````

## example 485

```````````````````````````````` example
[link]()
.
<p><a href="">link</a></p>
````````````````````````````````

## example 486

```````````````````````````````` example
[link](<>)
.
<p><a href="">link</a></p>
````````````````````````````````

## example 487

```````````````````````````````` example
[]()
.
<p><a href=""></a></p>
````````````````````````````````

## example 488

```````````````````````````````` example
[link](/my uri)
.
<p>[link](/my uri)</p>
````````````````````````````````

## example 489

```````````````````````````````` example
[link](</my uri>)
.
<p><a href="/my%20uri">link</a></p>
````````````````````````````````

## example 490

```````````````````````````````` example
[link](foo
bar)
.
<p>[link](foo
bar)</p>
````````````````````````````````

## example 491

```````````````````````````````` example
[link](<foo
bar>)
.
<p>[link](<foo
bar>)</p>
````````````````````````````````

## example 492

```````````````````````````````` example
[a](<b)c>)
.
<p><a href="b)c">a</a></p>
````````````````````````````````

## example 493

```````````````````````````````` example
[link](<foo\>)
.
<p>[link](&lt;foo&gt;)</p>
````````````````````````````````

## example 494

```````````````````````````````` example
[a](<b)c
[a](<b)c>
[a](<b>c)
.
<p>[a](&lt;b)c
[a](&lt;b)c&gt;
[a](<b>c)</p>
````````````````````````````````

## example 495

```````````````````````````````` example
[link](\(foo\))
.
<p><a href="(foo)">link</a></p>
````````````````````````````````

## example 496

```````````````````````````````` example
[link](foo(and(bar)))
.
<p><a href="foo(and(bar))">link</a></p>
````````````````````````````````

## example 497

```````````````````````````````` example
[link](foo(and(bar))
.
<p>[link](foo(and(bar))</p>
````````````````````````````````

## example 498

```````````````````````````````` example
[link](foo\(and\(bar\))
.
<p><a href="foo(and(bar)">link</a></p>
````````````````````````````````

## example 499

```````````````````````````````` example
[link](<foo(and(bar)>)
.
<p><a href="foo(and(bar)">link</a></p>
````````````````````````````````

## example 500

```````````````````````````````` example
[link](foo\)\:)
.
<p><a href="foo):">link</a></p>
````````````````````````````````

## example 501

```````````````````````````````` example
[link](#fragment)

[link](https://example.com#fragment)

[link](https://example.com?foo=3#frag)
.
<p><a href="#fragment">link</a></p>
<p><a href="https://example.com#fragment">link</a></p>
<p><a href="https://example.com?foo=3#frag">link</a></p>
````````````````````````````````

## example 502

```````````````````````````````` example
[link](foo\bar)
.
<p><a href="foo%5Cbar">link</a></p>
````````````````````````````````

## example 503

```````````````````````````````` example
[link](foo%20b&auml;)
.
<p><a href="foo%20b%C3%A4">link</a></p>
````````````````````````````````

## example 504

```````````````````````````````` example
[link]("title")
.
<p><a href="%22title%22">link</a></p>
````````````````````````````````

## example 505

```````````````````````````````` example
[link](/url "title")
[link](/url 'title')
[link](/url (title))
.
<p><a href="/url" title="title">link</a>
<a href="/url" title="title">link</a>
<a href="/url" title="title">link</a></p>
````````````````````````````````

## example 506

```````````````````````````````` example
[link](/url "title \"&quot;")
.
<p><a href="/url" title="title &quot;&quot;">link</a></p>
````````````````````````````````

## example 507

```````````````````````````````` example
[link](/url "title")
.
<p><a href="/url%C2%A0%22title%22">link</a></p>
````````````````````````````````

## example 508

```````````````````````````````` example
[link](/url "title "and" title")
.
<p>[link](/url &quot;title &quot;and&quot; title&quot;)</p>
````````````````````````````````

## example 509

```````````````````````````````` example
[link](/url 'title "and" title')
.
<p><a href="/url" title="title &quot;and&quot; title">link</a></p>
````````````````````````````````

## example 510

```````````````````````````````` example
[link](   /uri
  "title"  )
.
<p><a href="/uri" title="title">link</a></p>
````````````````````````````````

## example 511

```````````````````````````````` example
[link] (/uri)
.
<p>[link] (/uri)</p>
````````````````````````````````

## example 512

```````````````````````````````` example
[link [foo [bar]]](/uri)
.
<p><a href="/uri">link [foo [bar]]</a></p>
````````````````````````````````

## example 513

```````````````````````````````` example
[link] bar](/uri)
.
<p>[link] bar](/uri)</p>
````````````````````````````````

## example 514

```````````````````````````````` example
[link [bar](/uri)
.
<p>[link <a href="/uri">bar</a></p>
````````````````````````````````

## example 515

```````````````````````````````` example
[link \[bar](/uri)
.
<p><a href="/uri">link [bar</a></p>
````````````````````````````````

## example 516

```````````````````````````````` example
[link *foo **bar** `#`*](/uri)
.
<p><a href="/uri">link <em>foo <strong>bar</strong> <code>#</code></em></a></p>
````````````````````````````````

## example 517

```````````````````````````````` example
[![moon](moon.jpg)](/uri)
.
<p><a href="/uri"><img src="moon.jpg" alt="moon" /></a></p>
````````````````````````````````

## example 518

```````````````````````````````` example
[foo [bar](/uri)](/uri)
.
<p>[foo <a href="/uri">bar</a>](/uri)</p>
````````````````````````````````

## example 519

```````````````````````````````` example
[foo *[bar [baz](/uri)](/uri)*](/uri)
.
<p>[foo <em>[bar <a href="/uri">baz</a>](/uri)</em>](/uri)</p>
````````````````````````````````

## example 520

```````````````````````````````` example
![[[foo](uri1)](uri2)](uri3)
.
<p><img src="uri3" alt="[foo](uri2)" /></p>
````````````````````````````````

## example 521

```````````````````````````````` example
*[foo*](/uri)
.
<p>*<a href="/uri">foo*</a></p>
````````````````````````````````

## example 522

```````````````````````````````` example
[foo *bar](baz*)
.
<p><a href="baz*">foo *bar</a></p>
````````````````````````````````

## example 523

```````````````````````````````` example
*foo [bar* baz]
.
<p><em>foo [bar</em> baz]</p>
````````````````````````````````

## example 524

```````````````````````````````` example
[foo <bar attr="](baz)">
.
<p>[foo <bar attr="](baz)"></p>
````````````````````````````````

## example 525

```````````````````````````````` example
[foo`](/uri)`
.
<p>[foo<code>](/uri)</code></p>
````````````````````````````````

## example 526

```````````````````````````````` example
[foo<https://example.com/?search=](uri)>
.
<p>[foo<a href="https://example.com/?search=%5D(uri)">https://example.com/?search=](uri)</a></p>
````````````````````````````````

## example 527

```````````````````````````````` example
[foo][bar]

[bar]: /url "title"
.
<p><a href="/url" title="title">foo</a></p>
````````````````````````````````

## example 528

```````````````````````````````` example
[link [foo [bar]]][ref]

[ref]: /uri
.
<p><a href="/uri">link [foo [bar]]</a></p>
````````````````````````````````

## example 529

```````````````````````````````` example
[link \[bar][ref]

[ref]: /uri
.
<p><a href="/uri">link [bar</a></p>
````````````````````````````````

## example 530

```````````````````````````````` example
[link *foo **bar** `#`*][ref]

[ref]: /uri
.
<p><a href="/uri">link <em>foo <strong>bar</strong> <code>#</code></em></a></p>
````````````````````````````````

## example 531

```````````````````````````````` example
[![moon](moon.jpg)][ref]

[ref]: /uri
.
<p><a href="/uri"><img src="moon.jpg" alt="moon" /></a></p>
````````````````````````````````

## example 532

```````````````````````````````` example
[foo [bar](/uri)][ref]

[ref]: /uri
.
<p>[foo <a href="/uri">bar</a>]<a href="/uri">ref</a></p>
````````````````````````````````

## example 533

```````````````````````````````` example
[foo *bar [baz][ref]*][ref]

[ref]: /uri
.
<p>[foo <em>bar <a href="/uri">baz</a></em>]<a href="/uri">ref</a></p>
````````````````````````````````

## example 534

```````````````````````````````` example
*[foo*][ref]

[ref]: /uri
.
<p>*<a href="/uri">foo*</a></p>
````````````````````````````````

## example 535

```````````````````````````````` example
[foo *bar][ref]*

[ref]: /uri
.
<p><a href="/uri">foo *bar</a>*</p>
````````````````````````````````

## example 536

```````````````````````````````` example
[foo <bar attr="][ref]">

[ref]: /uri
.
<p>[foo <bar attr="][ref]"></p>
````````````````````````````````

## example 537

```````````````````````````````` example
[foo`][ref]`

[ref]: /uri
.
<p>[foo<code>][ref]</code></p>
````````````````````````````````

## example 538

```````````````````````````````` example
[foo<https://example.com/?search=][ref]>

[ref]: /uri
.
<p>[foo<a href="https://example.com/?search=%5D%5Bref%5D">https://example.com/?search=][ref]</a></p>
````````````````````````````````

## example 539

```````````````````````````````` example
[foo][BaR]

[bar]: /url "title"
.
<p><a href="/url" title="title">foo</a></p>
````````````````````````````````

## example 540

```````````````````````````````` example
[ẞ]

[SS]: /url
.
<p><a href="/url">ẞ</a></p>
````````````````````````````````

## example 541

```````````````````````````````` example
[Foo
  bar]: /url

[Baz][Foo bar]
.
<p><a href="/url">Baz</a></p>
````````````````````````````````

## example 542

```````````````````````````````` example
[foo] [bar]

[bar]: /url "title"
.
<p>[foo] <a href="/url" title="title">bar</a></p>
````````````````````````````````

## example 543

```````````````````````````````` example
[foo]
[bar]

[bar]: /url "title"
.
<p>[foo]
<a href="/url" title="title">bar</a></p>
````````````````````````````````

## example 544

```````````````````````````````` example
[foo]: /url1

[foo]: /url2

[bar][foo]
.
<p><a href="/url1">bar</a></p>
````````````````````````````````

## example 545

```````````````````````````````` example
[bar][foo\!]

[foo!]: /url
.
<p>[bar][foo!]</p>
````````````````````````````````

## example 546

```````````````````````````````` example
[foo][ref[]

[ref[]: /uri
.
<p>[foo][ref[]</p>
<p>[ref[]: /uri</p>
````````````````````````````````

## example 547

```````````````````````````````` example
[foo][ref[bar]]

[ref[bar]]: /uri
.
<p>[foo][ref[bar]]</p>
<p>[ref[bar]]: /uri</p>
````````````````````````````````

## example 548

```````````````````````````````` example
[[[foo]]]

[[[foo]]]: /url
.
<p>[[[foo]]]</p>
<p>[[[foo]]]: /url</p>
````````````````````````````````

## example 549

```````````````````````````````` example
[foo][ref\[]

[ref\[]: /uri
.
<p><a href="/uri">foo</a></p>
````````````````````````````````

## example 550

```````````````````````````````` example
[bar\\]: /uri

[bar\\]
.
<p><a href="/uri">bar\</a></p>
````````````````````````````````

## example 551

```````````````````````````````` example
[]

[]: /uri
.
<p>[]</p>
<p>[]: /uri</p>
````````````````````````````````

## example 552

```````````````````````````````` example
[
 ]

[
 ]: /uri
.
<p>[
]</p>
<p>[
]: /uri</p>
````````````````````````````````

## example 553

```````````````````````````````` example
[foo][]

[foo]: /url "title"
.
<p><a href="/url" title="title">foo</a></p>
````````````````````````````````

## example 554

```````````````````````````````` example
[*foo* bar][]

[*foo* bar]: /url "title"
.
<p><a href="/url" title="title"><em>foo</em> bar</a></p>
````````````````````````````````

## example 555

```````````````````````````````` example
[Foo][]

[foo]: /url "title"
.
<p><a href="/url" title="title">Foo</a></p>
````````````````````````````````

## example 556

```````````````````````````````` example
[foo] 
[]

[foo]: /url "title"
.
<p><a href="/url" title="title">foo</a>
[]</p>
````````````````````````````````

## example 557

```````````````````````````````` example
[foo]

[foo]: /url "title"
.
<p><a href="/url" title="title">foo</a></p>
````````````````````````````````

## example 558

```````````````````````````````` example
[*foo* bar]

[*foo* bar]: /url "title"
.
<p><a href="/url" title="title"><em>foo</em> bar</a></p>
````````````````````````````````

## example 559

```````````````````````````````` example
[[*foo* bar]]

[*foo* bar]: /url "title"
.
<p>[<a href="/url" title="title"><em>foo</em> bar</a>]</p>
````````````````````````````````

## example 560

```````````````````````````````` example
[[bar [foo]

[foo]: /url
.
<p>[[bar <a href="/url">foo</a></p>
````````````````````````````````

## example 561

```````````````````````````````` example
[Foo]

[foo]: /url "title"
.
<p><a href="/url" title="title">Foo</a></p>
````````````````````````````````

## example 562

```````````````````````````````` example
[foo] bar

[foo]: /url
.
<p><a href="/url">foo</a> bar</p>
````````````````````````````````

## example 563

```````````````````````````````` example
\[foo]

[foo]: /url "title"
.
<p>[foo]</p>
````````````````````````````````

## example 564

```````````````````````````````` example
[foo*]: /url

*[foo*]
.
<p>*<a href="/url">foo*</a></p>
````````````````````````````````

## example 565

```````````````````````````````` example
[foo][bar]

[foo]: /url1
[bar]: /url2
.
<p><a href="/url2">foo</a></p>
````````````````````````````````

## example 566

```````````````````````````````` example
[foo][]

[foo]: /url1
.
<p><a href="/url1">foo</a></p>
````````````````````````````````

## example 567

```````````````````````````````` example
[foo]()

[foo]: /url1
.
<p><a href="">foo</a></p>
````````````````````````````````

## example 568

```````````````````````````````` example
[foo](not a link)

[foo]: /url1
.
<p><a href="/url1">foo</a>(not a link)</p>
````````````````````````````````

## example 569

```````````````````````````````` example
[foo][bar][baz]

[baz]: /url
.
<p>[foo]<a href="/url">bar</a></p>
````````````````````````````````

## example 570

```````````````````````````````` example
[foo][bar][baz]

[baz]: /url1
[bar]: /url2
.
<p><a href="/url2">foo</a><a href="/url1">baz</a></p>
````````````````````````````````

## example 571

```````````````````````````````` example
[foo][bar][baz]

[baz]: /url1
[foo]: /url2
.
<p>[foo]<a href="/url1">bar</a></p>
````````````````````````````````

