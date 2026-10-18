# Code blocks: org-significant lines, info strings, indentation, containers (expected HTML: cmark-gfm form)

## code_org_lines

```````````````````````````````` example
```
* not a heading
#+end_src
#+begin_quote
,* comma
```
.
<pre><code>* not a heading
#+end_src
#+begin_quote
,* comma
</code></pre>
````````````````````````````````

## code_lang_params

```````````````````````````````` example
```python {.numberLines}
print(1)
```

```c++
int x;
```

```elisp
(+ 1 2)
```
.
<pre><code class="language-python">print(1)
</code></pre>
<pre><code class="language-c++">int x;
</code></pre>
<pre><code class="language-elisp">(+ 1 2)
</code></pre>
````````````````````````````````

## code_tilde_fence

```````````````````````````````` example
~~~ ruby
puts 1
~~~
.
<pre><code class="language-ruby">puts 1
</code></pre>
````````````````````````````````

## code_indent_all

```````````````````````````````` example
```
    indented
      more
```
.
<pre><code>    indented
      more
</code></pre>
````````````````````````````````

## code_in_list

```````````````````````````````` example
- item

  ```sh
  echo hi
  ```
.
<ul>
<li>
<p>item</p>
<pre><code class="language-sh">echo hi
</code></pre>
</li>
</ul>
````````````````````````````````

## quote_code

```````````````````````````````` example
> ```js
> x
> ```
.
<blockquote>
<pre><code class="language-js">x
</code></pre>
</blockquote>
````````````````````````````````

## list_code_indented

```````````````````````````````` example
- a

      code
.
<ul>
<li>
<p>a</p>
<pre><code>code
</code></pre>
</li>
</ul>
````````````````````````````````

