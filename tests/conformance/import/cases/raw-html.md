# Raw HTML blocks and inline HTML (expected HTML: cmark-gfm form)

## html_block_div

```````````````````````````````` example
<div class="x">

*md inside*

</div>
.
<div class="x">
<p><em>md inside</em></p>
</div>
````````````````````````````````

## html_comment_block

```````````````````````````````` example
<!-- a comment -->

para
.
<!-- a comment -->
<p>para</p>
````````````````````````````````

## html_details

```````````````````````````````` example
<details>
<summary>S</summary>

Body

</details>
.
<details>
<summary>S</summary>
<p>Body</p>
</details>
````````````````````````````````

## html_inline

```````````````````````````````` example
a <kbd>Ctrl</kbd> b <br> c <span style="color:red">red</span>
.
<p>a <kbd>Ctrl</kbd> b <br> c <span style="color:red">red</span></p>
````````````````````````````````

## html_block_pre

```````````````````````````````` example
<pre>
*x*
</pre>
.
<pre>
*x*
</pre>
````````````````````````````````

## html_block_script

```````````````````````````````` example
<script>
var a = 1;
</script>
.
&lt;script>
var a = 1;
&lt;/script>
````````````````````````````````

## html_block_type7_endblank

```````````````````````````````` example
<custom>
# not heading

# heading
.
<custom>
# not heading
<h1>heading</h1>
````````````````````````````````

## gfm_disallowed

```````````````````````````````` example
<title>x</title>
.
&lt;title>x&lt;/title>
````````````````````````````````

