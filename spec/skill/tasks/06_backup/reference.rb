def backup(path)
  destination = path.to_s + ".bak"
  Legate.cp!(path, destination)
  destination
end
