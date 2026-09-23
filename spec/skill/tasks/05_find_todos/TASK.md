Write `find_todos(glob)`.

It searches the text files matching `glob` for lines containing `TODO`, matched case-sensitively, and returns an Array of Strings of the form `"<file name>:<line number>"`, where the file name has no directory part and line numbers start at 1. Sort the Array.

Example: a file `notes.txt` whose second line contains `TODO` contributes `"notes.txt:2"`.
