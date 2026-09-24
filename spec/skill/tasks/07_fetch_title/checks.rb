require "assert"
require "wiretap"

title = wiretap("slideshow") { fetch_title("https://httpbin.org/json") }
assert_equal("Sample Slide Show", title)

missing = wiretap("not_found") { fetch_title("https://httpbin.org/status/404") }
assert_nil(missing)
