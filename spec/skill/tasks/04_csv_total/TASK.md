Write `csv_total(path, column)`.

The file at `path` is a CSV with a header row. `column` is a header name, given as a String. Return the sum of that column's values as an Integer. Every value in the column is a whole number.

Example: for a file containing

```
item,qty
apple,3
pear,10
```

`csv_total(path, "qty")` returns `13`.
