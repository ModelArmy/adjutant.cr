Write `backup(path)`.

It copies the file at `path` to a file beside it with `.bak` added to the name, and returns that new path as a String. If the `.bak` file already exists it is replaced, so calling `backup` twice in a row must not raise.

Example: `backup("notes.txt")` writes `notes.txt.bak` and returns `"notes.txt.bak"`.
