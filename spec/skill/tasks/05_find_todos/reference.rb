def find_todos(glob)
  Legate.grep("TODO", glob).map { |m| m.path.basename + ":" + m.line_no.to_s }.sort
end
