def top_words(path, n)
  counts = {}
  Legate.read(path).split.each { |w| counts[w] = (counts[w] || 0) + 1 }

  words = counts.keys.sort
  result = []
  c = counts.values.max || 0
  while c > 0 && result.size < n
    words.each { |w| result << w if counts[w] == c }
    c -= 1
  end
  result.first(n)
end
