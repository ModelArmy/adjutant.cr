def csv_total(path, column)
  key = column.to_sym
  total = 0
  Legate.records(path, format: :csv).each { |row| total += row[key].to_i }
  total
end
