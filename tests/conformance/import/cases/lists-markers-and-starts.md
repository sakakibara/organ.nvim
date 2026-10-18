# Lists: bullets, adjacency, ordered starts and delimiters, depth, looseness (expected HTML: cmark-gfm form)

## list_loose

```````````````````````````````` example
- a

- b

  para
- c
.
<ul>
<li>
<p>a</p>
</li>
<li>
<p>b</p>
<p>para</p>
</li>
<li>
<p>c</p>
</li>
</ul>
````````````````````````````````

## list_star

```````````````````````````````` example
* a
* b
  * c
.
<ul>
<li>a</li>
<li>b
<ul>
<li>c</li>
</ul>
</li>
</ul>
````````````````````````````````

## list_plus_after_minus

```````````````````````````````` example
- a


+ b
.
<ul>
<li>a</li>
</ul>
<ul>
<li>b</li>
</ul>
````````````````````````````````

## list_ol_paren

```````````````````````````````` example
1) a
2) b
.
<ol>
<li>a</li>
<li>b</li>
</ol>
````````````````````````````````

## list_ol_start

```````````````````````````````` example
5. a
6. b
.
<ol start="5">
<li>a</li>
<li>b</li>
</ol>
````````````````````````````````

## list_deep

```````````````````````````````` example
- a
  - b
    - c
      - d
.
<ul>
<li>a
<ul>
<li>b
<ul>
<li>c
<ul>
<li>d</li>
</ul>
</li>
</ul>
</li>
</ul>
</li>
</ul>
````````````````````````````````

## list_after_para_hr

```````````````````````````````` example
- a
- b

---

para
.
<ul>
<li>a</li>
<li>b</li>
</ul>
<hr />
<p>para</p>
````````````````````````````````

