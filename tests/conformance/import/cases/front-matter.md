# YAML and TOML front matter (metadata is consumed, not rendered) (expected HTML: cmark-gfm form)

## fm_yaml

```````````````````````````````` example
---
title: My Doc
author: Jane
date: 2024-01-02
tags: [a, b]
---

# Intro

Text.
.
<h1>Intro</h1>
<p>Text.</p>
````````````````````````````````

## fm_toml

```````````````````````````````` example
+++
title = "T"
+++

Text.
.
<p>Text.</p>
````````````````````````````````

