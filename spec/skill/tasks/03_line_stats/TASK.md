Write `line_stats(path)`.

It returns a Hash with two Symbol keys: `:lines`, the number of lines in the text file at `path`, and `:longest`, the length in characters of its longest line, not counting the newline. Empty lines count as lines.

The file may be larger than `Legate.read` is allowed to read in one go.

Example: a file containing `ab\n\nabcd\n` returns `{lines: 3, longest: 4}`.
