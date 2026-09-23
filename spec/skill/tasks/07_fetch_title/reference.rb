def fetch_title(url)
  response = Legate.fetch(url)
  return nil unless response.ok?
  response.json["slideshow"]["title"]
end
