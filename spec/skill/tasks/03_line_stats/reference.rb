def line_stats(path)
  lines = 0
  longest = 0
  Legate.lines(path).each do |line|
    lines += 1
    longest = line.length if line.length > longest
  end
  {lines: lines, longest: longest}
end
