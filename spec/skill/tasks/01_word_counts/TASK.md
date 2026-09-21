Write `word_counts(path)`.

It reads the text file at `path` and returns a Hash mapping each word to the number of times it appears. A word is any run of non-whitespace characters, compared case-insensitively, so keys are lowercase.

Example: a file containing `The cat saw the dog` returns `{"the" => 2, "cat" => 1, "saw" => 1, "dog" => 1}`.
