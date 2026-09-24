def config_value(name, fallback)
  Legate.env(name) || fallback
end
