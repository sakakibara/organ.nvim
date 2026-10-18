# Autolinks and extended autolinks in running text (expected HTML: cmark-gfm form)

## autolink_url

```````````````````````````````` example
<https://x.com>
.
<p><a href="https://x.com">https://x.com</a></p>
````````````````````````````````

## autolink_bare

```````````````````````````````` example
see https://x.com/a_b and www.y.com
.
<p>see <a href="https://x.com/a_b">https://x.com/a_b</a> and <a href="http://www.y.com">www.y.com</a></p>
````````````````````````````````

## autolink_email

```````````````````````````````` example
<a@b.com>
.
<p><a href="mailto:a@b.com">a@b.com</a></p>
````````````````````````````````

## autolink_sentence

```````````````````````````````` example
See <https://example.com> and www.example.org.
.
<p>See <a href="https://example.com">https://example.com</a> and <a href="http://www.example.org">www.example.org</a>.</p>
````````````````````````````````

