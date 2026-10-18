# Paragraph lines that begin with org element syntax (expected HTML: cmark-gfm form)

## line_starts

```````````````````````````````` example
para
: fixed
| t |
#+TITLE: x
#+begin_src
-----
- item
+ plus
1) one
CLOCK: [2024-01-01 Mon 10:00]
DEADLINE: <2024-01-01>
:PROPERTIES:
:END:
\begin{equation}
[fn:x] def
.
<h2>para
: fixed
| t |
#+TITLE: x
#+begin_src</h2>
<ul>
<li>item</li>
</ul>
<ul>
<li>plus</li>
</ul>
<ol>
<li>one
CLOCK: [2024-01-01 Mon 10:00]
DEADLINE: &lt;2024-01-01&gt;
:PROPERTIES:
:END:
\begin{equation}
[fn:x] def</li>
</ol>
````````````````````````````````

## para_start_hash

```````````````````````````````` example
\# not heading

\#+TITLE: no
.
<p># not heading</p>
<p>#+TITLE: no</p>
````````````````````````````````

## para_start_colon

```````````````````````````````` example
: colon start
.
<p>: colon start</p>
````````````````````````````````

## para_start_pipe

```````````````````````````````` example
\| pipe start |
.
<p>| pipe start |</p>
````````````````````````````````

## para_start_dash5

```````````````````````````````` example
\-----
.
<p>-----</p>
````````````````````````````````

## softbreak_hazard

```````````````````````````````` example
foo
* bar
.
<p>foo</p>
<ul>
<li>bar</li>
</ul>
````````````````````````````````

