Write `fetch_title(url)`.

It fetches `url`, which answers with JSON, and returns the value of the `title` key inside the `slideshow` object. If the response status is not a success, return nil instead. Do not raise on a failed request.

Example: for a body of `{"slideshow": {"title": "Sample Slide Show"}}`, it returns `"Sample Slide Show"`.
