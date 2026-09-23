# Legate.fetch against transcripts recorded with `require "wiretap"`.
# To re-record, delete transcripts/*.json and run with WIRETAP_RECORD=1.
require "assert"
require "wiretap"

response = wiretap("get_json") { Legate.fetch("https://httpbin.org/json") }

assert_equal(200, response.status)
assert_true(response.ok?)
assert("the JSON body parses to a Hash") { response.json.is_a?(Hash) }

assert("wiretap returns its block's value") { wiretap("no_requests") { 42 } == 42 }
assert_raise { wiretap("../escape") { 1 } }
assert_raise { wiretap("no_block") }
