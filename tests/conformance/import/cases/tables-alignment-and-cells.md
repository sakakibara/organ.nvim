# GFM tables: alignment, inline cells, numeric columns, ragged rows (expected HTML: cmark-gfm form)

## table_align

```````````````````````````````` example
| L | C | R | N |
|:--|:-:|--:|---|
| a | b | c | 1 |
| aa | bb | cc | 22 |
.
<table>
<thead>
<tr>
<th align="left">L</th>
<th align="center">C</th>
<th align="right">R</th>
<th>N</th>
</tr>
</thead>
<tbody>
<tr>
<td align="left">a</td>
<td align="center">b</td>
<td align="right">c</td>
<td>1</td>
</tr>
<tr>
<td align="left">aa</td>
<td align="center">bb</td>
<td align="right">cc</td>
<td>22</td>
</tr>
</tbody>
</table>
````````````````````````````````

## table_inline

```````````````````````````````` example
| a | b |
|---|---|
| `x\|y` | [l](http://e.com) |
| *e* | **s** |
| | empty |
.
<table>
<thead>
<tr>
<th>a</th>
<th>b</th>
</tr>
</thead>
<tbody>
<tr>
<td><code>x|y</code></td>
<td><a href="http://e.com">l</a></td>
</tr>
<tr>
<td><em>e</em></td>
<td><strong>s</strong></td>
</tr>
<tr>
<td></td>
<td>empty</td>
</tr>
</tbody>
</table>
````````````````````````````````

## table_numeric

```````````````````````````````` example
| h | n |
|---|---|
| x | 1 |
| y | 2 |
.
<table>
<thead>
<tr>
<th>h</th>
<th>n</th>
</tr>
</thead>
<tbody>
<tr>
<td>x</td>
<td>1</td>
</tr>
<tr>
<td>y</td>
<td>2</td>
</tr>
</tbody>
</table>
````````````````````````````````

## table_missing

```````````````````````````````` example
| a | b | c |
|---|---|---|
| 1 |
| 1 | 2 | 3 | 4 |
.
<table>
<thead>
<tr>
<th>a</th>
<th>b</th>
<th>c</th>
</tr>
</thead>
<tbody>
<tr>
<td>1</td>
<td></td>
<td></td>
</tr>
<tr>
<td>1</td>
<td>2</td>
<td>3</td>
</tr>
</tbody>
</table>
````````````````````````````````

