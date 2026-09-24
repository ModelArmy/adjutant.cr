def keep_lines(path)
  lines = Legate.lines(path).to_a
  kept = []
  i = 0
  while i < lines.size
    line = lines[i]
    kept << line if yield(line)
    i = i + 1
  end
  kept
end
