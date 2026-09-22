---
name: adjutant
description: Write scripts for Adjutant, a sandboxed subset of Ruby whose only way to touch files, the network or the environment is the Legate API. Use this skill whenever asked to write, fix or explain a script that will run under Adjutant or Legate, even if the request just says "Ruby script" in an Adjutant context.
---

# Adjutant

Adjutant runs a subset of Ruby. Syntax you know from Ruby works unless this document says otherwise: classes, modules, methods with default, keyword and splat parameters, blocks, `yield`, lambdas, `case`/`when`, `begin`/`rescue`/`ensure`, `while`/`until`/`loop`, string interpolation, heredocs, `%w[]`, `&.` and `||=`. Name block parameters explicitly: `{ |x| ... }`.

What is different, in order of importance:

1. **The outside world is reached only through `Legate`.** There is no `File`, `Dir`, `IO`, `ENV`, `Net::HTTP`, `system` or backticks.
2. **Built-in classes have only the methods listed in section 3.** Anything else raises `NoMethodError`, however common it is in Ruby.
3. **The script runs under a policy.** It may touch only what the policy grants. A refusal is fatal and cannot be rescued; see section 5.
4. **Errors name their fix.** Each carries a code and a hint; apply the hint rather than trying another route.

## 1. Instead of X, write Y

- `File.read(p)` → `Legate.read(p)`
- `File.write(p, s)` → `Legate.write(p, s)`; use `Legate.write!` to replace an existing file
- `File.exist?(p)`, `File.size(p)` → `Legate.stat(p)` (nil if absent), then `.size`
- `File.foreach(p)`, `IO.readlines` → `Legate.lines(p).each { ... }`
- `Dir.glob("**/*.rb")` → `Legate.list("**/*.rb")`
- `FileUtils.rm_rf(d)` → `Legate.rmdir!(d)`
- `ENV["X"]` → `Legate.env("X")`
- `Net::HTTP`, `open-uri` → `Legate.fetch(url)`
- `JSON.parse(s)` → `response.json` for HTTP; `Legate.records(p, format: :jsonl)` for files. No general JSON parser.
- `obj.to_json` → Build the string with interpolation. No JSON generator.
- `` `grep ...` ``, `system` → `Legate.grep(pattern, paths)`; nothing runs processes
- `rand`, `Time.now` → `Legate.random`, `Legate.now`
- `arr.each_with_index { |x, i| }` → `arr.each { |x| ...; i += 1 }` with `i = 0` before
- `arr.sum` → `arr.inject(0) { |acc, x| acc + x }`
- `arr.inject(:+)` → `arr.inject(0) { |acc, x| acc + x }`; `inject` needs a block
- `arr.sort { |a, b| b <=> a }` → `arr.sort.reverse`; `sort` ignores a block
- `arr.sort_by { ... }`, `max_by`, sorting `[key, item]` pairs → Sort a flat list of Strings or numbers, then look the items up. Arrays do not compare, so a list of pairs comes back unsorted.
- `arr.uniq` → `seen = {}; arr.each { |x| seen[x] = true }; seen.keys`
- `arr.count { ... }` → `arr.select { ... }.size`
- `arr.find { ... }` → `arr.select { ... }.first`
- `arr.group_by { ... }` → A Hash of Arrays built in `each`
- `arr.map(&:name)` → `arr.map { |x| x.name }`
- `arr[1..3]` → `arr.first(n)`, `arr.last(n)`; Arrays do not slice by Range
- `hash.map`, `select`, `sort_by`, `find` → `hash.to_a.map { |pair| ... }` or `hash.each { |k, v| ... }`
- `hash.fetch(k, d)`, `dig` → `hash.key?(k) ? hash[k] : d`; chain `[]`
- `"ab" * 3`, `"%d" % n`, `format` → Interpolation: `"#{n}"`
- `str << "x"` → `str = str + "x"`
- `x ** 2` → `x * x`
- `3.7.round` → `(3.7 + 0.5).floor` for positives; Float has only `to_i`, `to_f`, `to_s`, `infinite?`
- `obj.count += 1` → `obj.count = obj.count + 1`
- `foo(*args)` → Pass the Array itself
- `.method` at the start of a line → End the previous line with `.` instead
- `retry` → A `while` loop around `begin`/`rescue`, with an attempt counter
- `def run(&blk)`, `block_given?` → `yield`
- `proc { }` → `lambda { }` or `-> { }`
- `send(:name)`, `define_method`, `eval` → A `case` on the name
- `private`, `protected` → Leave methods public
- `def ==(o)`, `def <=>(o)`, `def +(o)` → A named method, such as `same_as?(o)`
- `Struct.new(:a, :b)` → A class with `attr_accessor :a, :b`
- `class << self` → `def self.name`
- `$global` → A constant, or pass the value along
- `def sq(x) = x * x` → `def sq(x)` ... `end`
- `0644` → Decimal: a leading zero is not octal here
- `defined?(x)` → Initialise `x` first

## 2. Language details

- `nil` and `false` are falsy; everything else is truthy.
- Integer division floors: `7 / 2` is `3`.
- `Hash#[]` returns `nil` for a missing key. Symbol and String keys differ.
- Top-level `puts`, `print` and `p` work. `Legate.log` is for structured records.
- Raise with `raise "message"` or `raise SomeError, "message"`. Define your own errors as `class MyError < StandardError; end`.

## 3. Built-in methods

These are complete lists. Operators `==`, `!=`, `<`, `<=`, `>`, `>=`, `<=>` order numbers and Strings only. Comparing anything else, including two Arrays, gives `false` rather than an error, so `sort`, `min` and `max` only work on lists of numbers or of Strings.

**Every object**: `nil?` `is_a?` `kind_of?` `class` `respond_to?` `equal?` `dup` `clone` `to_s` `inspect`

**Integer**: `+ - * / %` `& | ^ << >>` `abs` `ceil` `floor` `round` `truncate` `even?` `odd?` `zero?` `next` `succ` `times` `to_i` `to_f` `to_s`

**Float**: `+ - * / %` `to_i` `to_f` `to_s` `infinite?`

**String**: `+` `[i]` `[range]` `=~` `length` `size` `empty?` `upcase` `downcase` `capitalize` `strip` `chomp` `reverse` `chars` `each_line` `split` `include?` `start_with?` `end_with?` `index` `rindex` `sub` `gsub` `match` `to_i` `to_f` `to_sym`

**Symbol**: `to_s` `to_sym`

**Array**: `[i]` `[i]=` `<<` `+` `push` `pop` `first` `first(n)` `last` `last(n)` `length` `size` `empty?` `include?` `each` `map` `select` `reject` `inject` `reduce` `all?` `any?` `min` `max` `sort` `reverse` `join(sep)`

**Hash**: `[k]` `[k]=` `each { |k, v| }` `keys` `values` `key?` `has_key?` `include?` `delete` `merge` `length` `size` `empty?` `to_a`

**Range**: `each` `step` `to_a` `first` `last` `begin` `end` `min` `max` `include?` `member?` `exclude_end?`

**Regexp**: `=~` `match` `match?` `source` `options` `casefold?`. **MatchData**: `[n]` `captures` `pre_match` `post_match` `begin` `end` `string`

**Proc**: `call` `lambda?`

**Time**: `Time.now` `Time.at` `+` `-` `<=>` `year` `month` `mon` `day` `mday` `hour` `min` `sec` `usec` `wday` `yday` `zone` `utc?` `utc_offset` `to_i` `to_f`

## 4. Legate

Every verb that takes a path accepts a String or a `Legate::Path`. Prefer paths: `Legate::Path.new("logs") / "app.log"` joins, and refuses `..` or an absolute right-hand side.

**Read** (grant `read`)
- `Legate.read(path, missing: :raise)` → String. `missing: nil` returns nil when absent.
- `Legate.stat(path)` → `Legate::Stat` or nil: `type` (`:file`, `:dir`, `:symlink`, `:other`), `size`, `mtime`, `file?`, `dir?`
- `Legate.list(glob)` → Array of `Legate::Entry`: `path`, `type`, `size`, `mtime`. Sorted; empty if none match.
- `Legate.grep(regexp_or_string, glob_or_paths, context: 0)` → Array of `Legate::Match`: `path`, `line_no`, `text`, `before`, `after`

**Stream** (grant `read`). Lazy and single-pass; re-call the verb to read again.
- `Legate.lines(path)`, `Legate.bytes(path)`, `Legate.records(path, format: :jsonl)` or `format: :csv`
- Records are Hashes with **Symbol** keys (`r[:name]`). Nested JSON keeps String keys. CSV values are Strings. `headers: false` gives Arrays.
- Streams support only `map` `select` `reject` `take(n)` `first(n)` `each` `count` `sum` `to_a`.

**Write** (grant `write`). Parent directories are created.
- `Legate.write(path, data)` refuses an existing file; `Legate.write!` replaces it. `Legate.append(path, data)`. Each returns bytes written. `data` may be a String or a stream.
- `Legate.mkdir(path)` succeeds if it exists. `Legate.cp(from, to)`, `Legate.cp!`; `recursive: true` for directories.

**Delete** (grant `delete`)
- `Legate.rm(path)` a file; `Legate.rmdir(path)` an empty directory; `Legate.rmdir!(path)` a whole tree. Missing is not an error.
- `Legate.mv(from, to)`, `Legate.mv!` need both `delete` and `write`.

**Network** (grant `net`)
- `Legate.fetch(url, method: :get, headers: {}, body: nil, timeout: 30)` → `Legate::Response`: `status`, `ok?`, `headers`, `body`, `url`, `json`, `raise!`
- A non-2xx status is returned, not raised. Call `raise!` to make it an error.

**Ambient**
- `Legate.scratch` → a writable temporary directory, emptied when the run ends
- `Legate.env(name)` → String, or nil if unset. Names outside the policy's list are refused.
- `Legate.now` → Time. `Legate.random` → Float in [0, 1); `Legate.random(n)` → [0, n)
- `Legate.log(message, fields = {})` records a structured line. `Legate.fail(message)` stops the run.

## 5. Errors

Recoverable errors are `StandardError`s; rescue them when you can act on them:
`Legate::NotFound` `Legate::Conflict` (destination exists: use the `!` verb, or choose another path) `Legate::Malformed` `Legate::TooLarge` (use a streaming verb) `Legate::TooMany` `Legate::Timeout` `Legate::Transport` `Legate::Redirect`

Fatal errors end the run and cannot be rescued, even with `rescue Exception`:
`Legate::Denied` (the policy does not grant this) `Legate::Exhausted` (a run budget is spent) `Legate::Aborted` (`Legate.fail`)

A denial means the script asked for something it was not given. Do not try another path, host or variable to get around it; change what the script needs, or report that it needs more.

What does not raise: `Legate.stat` on a missing path (nil), `Legate.rm`/`rmdir` on a missing path (`false`), `rmdir!` (`0`), an HTTP error status.

## 6. Reading a diagnostic

Each error starts `error[CODE]:` followed by a source excerpt, a `why:` and usually a `help:`. The letter says what to do: `P` fix the syntax; `U` use the alternative in `help:`; `R` fix the script; `F` the risk policy refused a data flow, so don't send that data there. Change only what the diagnostic points at.
