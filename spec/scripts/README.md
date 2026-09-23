# `spec/scripts`

This folder contains test scripts.

- Run `ops build` to build the test runner
- Run `bin/debug/test_runner`

## HTTP in a script spec

`Legate.fetch` must never reach a real server during a test run. Wrap the
call in `wiretap`, which replays a recorded transcript:

```ruby
require "wiretap"

response = wiretap("get_json") { Legate.fetch("https://httpbin.org/json") }
```

- Transcripts live in `transcripts/<name>.json` beside the script, and are
  committed. `spec/scripts/legate/fetch_recorded/` is a worked example.
- Every run replays. A request with no matching interaction fails loudly
  rather than reaching the network.
- To record, or re-record after deleting a transcript, run the test runner
  once with `WIRETAP_RECORD=1`. That reaches the real host, so it needs
  network access. Commit what it writes.
- `wiretap` exists only in the test runner. An embedder's interpreter
  never has it, since its traffic would bypass Legate's grants.
