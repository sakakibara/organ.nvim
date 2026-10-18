# CommonMark 0.31.2 spec, section "Fenced code blocks"

## example 119

```````````````````````````````` example
```
<
 >
```
.
<pre><code>&lt;
 &gt;
</code></pre>
````````````````````````````````

## example 120

```````````````````````````````` example
~~~
<
 >
~~~
.
<pre><code>&lt;
 &gt;
</code></pre>
````````````````````````````````

## example 121

```````````````````````````````` example
``
foo
``
.
<p><code>foo</code></p>
````````````````````````````````

## example 122

```````````````````````````````` example
```
aaa
~~~
```
.
<pre><code>aaa
~~~
</code></pre>
````````````````````````````````

## example 123

```````````````````````````````` example
~~~
aaa
```
~~~
.
<pre><code>aaa
```
</code></pre>
````````````````````````````````

## example 124

```````````````````````````````` example
````
aaa
```
``````
.
<pre><code>aaa
```
</code></pre>
````````````````````````````````

## example 125

```````````````````````````````` example
~~~~
aaa
~~~
~~~~
.
<pre><code>aaa
~~~
</code></pre>
````````````````````````````````

## example 126

```````````````````````````````` example
```
.
<pre><code></code></pre>
````````````````````````````````

## example 127

```````````````````````````````` example
`````

```
aaa
.
<pre><code>
```
aaa
</code></pre>
````````````````````````````````

## example 128

```````````````````````````````` example
> ```
> aaa

bbb
.
<blockquote>
<pre><code>aaa
</code></pre>
</blockquote>
<p>bbb</p>
````````````````````````````````

## example 129

```````````````````````````````` example
```

  
```
.
<pre><code>
  
</code></pre>
````````````````````````````````

## example 130

```````````````````````````````` example
```
```
.
<pre><code></code></pre>
````````````````````````````````

## example 131

```````````````````````````````` example
 ```
 aaa
aaa
```
.
<pre><code>aaa
aaa
</code></pre>
````````````````````````````````

## example 132

```````````````````````````````` example
  ```
aaa
  aaa
aaa
  ```
.
<pre><code>aaa
aaa
aaa
</code></pre>
````````````````````````````````

## example 133

```````````````````````````````` example
   ```
   aaa
    aaa
  aaa
   ```
.
<pre><code>aaa
 aaa
aaa
</code></pre>
````````````````````````````````

## example 134

```````````````````````````````` example
    ```
    aaa
    ```
.
<pre><code>```
aaa
```
</code></pre>
````````````````````````````````

## example 135

```````````````````````````````` example
```
aaa
  ```
.
<pre><code>aaa
</code></pre>
````````````````````````````````

## example 136

```````````````````````````````` example
   ```
aaa
  ```
.
<pre><code>aaa
</code></pre>
````````````````````````````````

## example 137

```````````````````````````````` example
```
aaa
    ```
.
<pre><code>aaa
    ```
</code></pre>
````````````````````````````````

## example 138

```````````````````````````````` example
``` ```
aaa
.
<p><code> </code>
aaa</p>
````````````````````````````````

## example 139

```````````````````````````````` example
~~~~~~
aaa
~~~ ~~
.
<pre><code>aaa
~~~ ~~
</code></pre>
````````````````````````````````

## example 140

```````````````````````````````` example
foo
```
bar
```
baz
.
<p>foo</p>
<pre><code>bar
</code></pre>
<p>baz</p>
````````````````````````````````

## example 141

```````````````````````````````` example
foo
---
~~~
bar
~~~
# baz
.
<h2>foo</h2>
<pre><code>bar
</code></pre>
<h1>baz</h1>
````````````````````````````````

## example 142

```````````````````````````````` example
```ruby
def foo(x)
  return 3
end
```
.
<pre><code class="language-ruby">def foo(x)
  return 3
end
</code></pre>
````````````````````````````````

## example 143

```````````````````````````````` example
~~~~    ruby startline=3 $%@#$
def foo(x)
  return 3
end
~~~~~~~
.
<pre><code class="language-ruby">def foo(x)
  return 3
end
</code></pre>
````````````````````````````````

## example 144

```````````````````````````````` example
````;
````
.
<pre><code class="language-;"></code></pre>
````````````````````````````````

## example 145

```````````````````````````````` example
``` aa ```
foo
.
<p><code>aa</code>
foo</p>
````````````````````````````````

## example 146

```````````````````````````````` example
~~~ aa ``` ~~~
foo
~~~
.
<pre><code class="language-aa">foo
</code></pre>
````````````````````````````````

## example 147

```````````````````````````````` example
```
``` aaa
```
.
<pre><code>``` aaa
</code></pre>
````````````````````````````````

