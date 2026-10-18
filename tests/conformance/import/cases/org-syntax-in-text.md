# Literal text that is org syntax: markup, sub/superscripts, special strings, entities, LaTeX, org objects (expected HTML: cmark-gfm form)

## text_subsup

```````````````````````````````` example
a_b x^2 H_2O file_name_here 10^3
.
<p>a_b x^2 H_2O file_name_here 10^3</p>
````````````````````````````````

## text_special

```````````````````````````````` example
a -- b --- c ... d \- e
.
<p>a -- b --- c ... d - e</p>
````````````````````````````````

## text_entities

```````````````````````````````` example
\alpha \beta \to \nbsp \\ foo
.
<p>\alpha \beta \to \nbsp \ foo</p>
````````````````````````````````

## text_math

```````````````````````````````` example
$x$ and $$y$$ and \(z\) and \[w\]
.
<p>$x$ and $$y$$ and (z) and [w]</p>
````````````````````````````````

## text_orgsyntax

```````````````````````````````` example
[fn:1] <<target>> <<<radio>>> {{{macro}}} @@html:<b>@@ [[link]] [[a][b]] <2024-01-01 Mon> [2024-01-01 Mon] [1/2] [50%] <%%(diary)>
.
<p>[fn:1] &lt;<target>&gt; &lt;&lt;<radio>&gt;&gt; {{{macro}}} @@html:<b>@@ [[link]] [[a][b]] &lt;2024-01-01 Mon&gt; [2024-01-01 Mon] [1/2] [50%] &lt;%%(diary)&gt;</p>
````````````````````````````````

## text_cite

```````````````````````````````` example
[cite:@key] and src_python{1+1} and call_f()
.
<p>[cite:@key] and src_python{1+1} and call_f()</p>
````````````````````````````````

## bracket_text

```````````````````````````````` example
[not a link] and [[double]]
.
<p>[not a link] and [[double]]</p>
````````````````````````````````

## esc_markup

```````````````````````````````` example
\*a\* \_b\_ \~c\~ \=d= +e+ /f/ =g= ~h~
.
<p>*a* _b_ ~c~ =d= +e+ /f/ =g= <del>h</del></p>
````````````````````````````````

## org_markup_lit

```````````````````````````````` example
a /b/ c +d+ e =f= g ~h~
.
<p>a /b/ c +d+ e =f= g <del>h</del></p>
````````````````````````````````

