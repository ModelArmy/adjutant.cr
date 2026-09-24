def word_counts(path)
  counts = {}
  Legate.read(path).split.each do |word|
    key = word.downcase
    counts[key] = (counts[key] || 0) + 1
  end
  counts
end
