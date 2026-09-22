Write `top_words(path, n)`.

It reads the text file at `path`, counts each word (any run of non-whitespace characters, compared exactly as written), and returns an Array of the `n` most frequent words, most frequent first. Words with the same count are ordered alphabetically. If there are fewer than `n` distinct words, return them all. `n` is at least 1.

Example: a file containing `b a c a b a` returns `["a", "b", "c"]` for `n = 3`, and `["a"]` for `n = 1`.
