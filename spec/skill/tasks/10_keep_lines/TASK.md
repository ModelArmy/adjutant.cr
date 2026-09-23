Write `keep_lines(path)`.

It reads the text file at `path` and gives each line, without its newline, to the block it is called with. It returns an Array of the lines the block answered truthily for, in the order they appear in the file.

Example: for a file of `one`, `two`, `three`, `keep_lines(path) { |line| line.length == 3 }` returns `["one", "two"]`.
