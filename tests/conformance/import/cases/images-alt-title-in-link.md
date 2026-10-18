# Images: alt text, titles, images inside links (expected HTML: cmark-gfm form)

## img_alt

```````````````````````````````` example
![alt text](pic.png)

Inline ![i](a.jpg) image.
.
<p><img src="pic.png" alt="alt text" /></p>
<p>Inline <img src="a.jpg" alt="i" /> image.</p>
````````````````````````````````

## img_title

```````````````````````````````` example
![a](p.png "T")
.
<p><img src="p.png" alt="a" title="T" /></p>
````````````````````````````````

## img_in_link

```````````````````````````````` example
[![b](badge.svg)](http://ci)
.
<p><a href="http://ci"><img src="badge.svg" alt="b" /></a></p>
````````````````````````````````

