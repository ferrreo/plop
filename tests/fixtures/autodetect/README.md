# Autodetection fixtures

This corpus covers all 203 zhl grammar names built by plop.

Fixtures marked `MIT` are excerpts from `github-linguist/linguist` pinned at
`8afc9a0110df1b62c723d51bea82bd29345f92d3`. Their exact source paths are recorded in `manifest.tsv`; license
text is in `LICENSE-LINGUIST-MIT.txt`. Fixtures marked `BSD-3-Clause` were
written for plop and are covered by `LICENSE-PLOP-BSD-3-CLAUSE.txt`.

Equivalent zhl aliases share one expected detector result because pasted
source has no filename with which to distinguish aliases.

Regenerate after building zhl's full grammar-name registry:

```sh
zig build -Doptimize=ReleaseFast
python3 tools/update_autodetect_corpus.py /path/to/github-linguist
```

Use Linguist revision `8afc9a0110df1b62c723d51bea82bd29345f92d3` to reproduce this exact corpus.
