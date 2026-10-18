# GFM task lists and strikethrough (expected HTML: cmark-gfm form)

## task_nested

```````````````````````````````` example
- [ ] a
  - [x] b
  - [X] c
1. [ ] d
.
<ul>
<li><input disabled="" type="checkbox"> a
<ul>
<li><input checked="" disabled="" type="checkbox"> b</li>
<li><input checked="" disabled="" type="checkbox"> c</li>
</ul>
</li>
</ul>
<ol>
<li><input disabled="" type="checkbox"> d</li>
</ol>
````````````````````````````````

## strike

```````````````````````````````` example
~~del~~ and ~one~ and a~~b~~c
.
<p><del>del</del> and <del>one</del> and a<del>b</del>c</p>
````````````````````````````````

