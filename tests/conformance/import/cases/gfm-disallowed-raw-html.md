# GFM 0.29 spec extension, section "Disallowed Raw HTML (extension)"

## example 652

```````````````````````````````` example
<strong> <title> <style> <em>

<blockquote>
  <xmp> is disallowed.  <XMP> is also disallowed.
</blockquote>
.
<p><strong> &lt;title> &lt;style> <em></p>
<blockquote>
  &lt;xmp> is disallowed.  &lt;XMP> is also disallowed.
</blockquote>
````````````````````````````````

