# `spec/scripts/rubyspec`

Ruby's own specification, from [ruby/spec](https://github.com/ruby/spec)
(MIT, see `LICENSE`), translated to the `assert` API and cut down to the
subset Adjutant supports. Each file is named after the spec it comes
from, less `_spec`, and its first line names that spec and the
ruby/spec commit it was taken at.

## Translating a spec

1. Each `it` becomes one `assert("<describe> <it>") do ... end`, the
   `describe` texts joined in front, so a failure reads as a sentence.
2. Expectations become assertions: `actual.should == expected` is
   `assert_equal(expected, actual)`, `should_not ==` is
   `assert_not_equal`, `should be_nil` is `assert_nil`,
   `should be_true` / `be_false` are `assert_equal(true, ...)` /
   `assert_equal(false, ...)`, since `assert_true` and `assert_false`
   accept any truthy or falsy value, and
   `-> { ... }.should raise_error(E)` is `assert_raise(E) { ... }`.
   An expression that ends in `.should`, such as `if ... end.should`,
   is assigned to `result` first.
3. mspec's helpers become plain Ruby: `mock("x")` is `Object.new`, and
   `ScratchPad` is a local array the test's blocks close over.
4. `eval "code"` that only puts off parsing becomes `code`. A test of
   `eval` itself, or of a `SyntaxError` raised through it, is blocked
   (U006).
5. `proc { }` becomes `->() { }` where the test isn't about procs
   (U019). Methods a test defines get names unique to the file.
6. A test Adjutant can't run is commented out under
   `# --- BLOCKED: <reason>`, as in `spec/scripts/mruby`. The reason
   names the U-code (UNSUPPORTED.md) or the SCOPE.md entry. A test that
   fails where Ruby passes is a divergence: it gets a SCOPE.md entry
   before it is blocked.
7. A version guard (`ruby_version_is`) keeps the branch for the current
   Ruby. Tests of warnings, `$` globals and encodings are blocked.
8. A spec's fixture is copied in after a `ScratchPad` stand-in, a
   module with `record`, `recorded` and `clear`. Scripts can't define
   `<<` (U017), so `ScratchPad << v` is `ScratchPad.recorded << v`. A
   fixture method Adjutant can't parse is commented out under
   `# --- BLOCKED:`, with the tests that call it, and `private :name`
   is left out, the method staying public (U008).
9. Where a test uses a construct only incidentally, Adjutant can't
   parse it, and Ruby has an equivalent spelling, the test uses that
   spelling, and the SCOPE.md entry says so, to be undone with the
   fix: `redo if c` as an `if` block, `{ break }` as `{ break; }`, a
   fixture's superclass defined at top level.

The runner caps each file at 500,000 instructions, so a long spec is
split by `describe`. A parse error stops a whole file, so a construct
that doesn't parse is blocked before anything else in its file can
run.

Every file passes on Ruby itself before it is committed, so a failure
here is Adjutant's, not the translation's.
