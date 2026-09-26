# Scope

Outstanding work: the known defects and gaps. HANDOFF.md says how to
work; this file says what is left.

Deliberate exclusions are not tracked here; they are in
[UNSUPPORTED.md](./UNSUPPORTED.md). The closing section explains the
difference.

An item lives in exactly one of the two sections below, and is removed
when resolved rather than marked done; the commit log is the history.
An entry names where to start (a file, a method) and says whether the
defect was predicted by reading the code or confirmed by a spec or a
model (HANDOFF.md §3.4).

## Must Fix

Security and policy defects, anything Adjutant accepts and then runs
differently from Ruby (HANDOFF.md §3.1), and changes that get dearer
after 1.0. Ordered for working through: security and policy defects
first, then the Ruby divergences, then design work on policy and
configuration.

- **Comparing self-containing containers overflows the host's
  stack.** Predicted by reading `value_ops.cr`.
  `ValueOps.equal?` compares Arrays and Hashes element by element,
  recursing on the Crystal stack with no cycle check, so
  `a = []; a << a; a == a.dup` recurses until the stack overflows,
  which ends the host process rather than the script. `inspect` guards
  the same shape (`guard_rendering`); Ruby's `==` detects the
  recursion and answers. `Array#include?`, `Hash#==` and anything else
  reaching `equal?` share it. The fix is a guard on the pair being
  compared, as `guard_rendering` does for one container.

- **A path on another Windows drive passes root containment.**
  Predicted by reading `grants.cr`; no spec has hit it.
  `Grants#under?` and `#under_maybe_missing?` call
  `Path#relative_to`, which returns the target path unchanged when
  its anchor differs from the root's (Crystal's `relative_to?` returns
  nil). The check then sees a first component that isn't `..` and
  counts the path as inside, so with a root of `C:\work`, a path on
  `D:\` is allowed. POSIX is unaffected, since every resolved path
  shares the anchor `/`. The fix is `relative_to?`, with nil counting
  as outside; a spec needs two drives, or a UNC path against a drive
  root.

- **A risk-flow policy with no rule for an authority allows sensitive
  data through it.** `RiskFlowPolicy#action_for` returns Allow when
  no rule matches, so a policy that marks `/etc/passwd` High and has
  rules for `Net` and `Delete` but not `Write` (as
  `samples/run_script.cr`'s does) lets a script copy the file into a
  granted output directory without a prompt. The perimeter passes it,
  since the directory is granted; nothing flags the missing row.
  Decided: reject an incomplete policy when it is built,
  not at run time, so the mistake reaches the policy's author rather
  than an unattended run.
  1. A policy (other than `reject_all`) must have a rule for every
     pair of a sink authority (`Read`, `Write`, `Delete`, `Net`,
     `Log`; not `Ambient`, which is grant-only) and a sensitivity
     above None (`Elevated`, `High`).
  2. Checked in the constructor, so `from_json` and code-built
     policies both get it. A host configuration error: a Crystal
     exception like AmbiguousRiskFlowPolicyError, not script-visible
     and not in the error catalog; its message lists every missing
     pair.
  3. With complete tables, the no-rule Allow default in
     `action_for` becomes unreachable and can be removed.
  4. About 45 construction sites in `src/`, `spec/` and `samples/`
     build partial policies and need full tables. Worth deciding
     whether a helper that fills unlisted pairs with one explicit
     action (for example `default: Ask`) is allowed; it keeps specs
     short but reintroduces a default, just a stated one.

- **`sub` and `gsub` drop the replacement's label.** Their result's
  label joins the receiver's and the pattern's only, so
  `"x".sub("x", secret)` returns `secret`'s text unlabelled, and so
  does `s.gsub(/./) { secret }`: a script can strip a label by
  substitution and pass the data to a sink the policy would have
  stopped. `string_sub_or_gsub` builds the result with one
  `String.build`; the fix is joining the replacement's label, or every
  block result's, into the result's, which over-labels but never
  under-labels.

- **`Legate.lines`, `bytes` and `records` skip the argument risk-flow
  check.** Predicted by reading the verb files. `read`, `stat`, `list`
  and `grep` declare `authorities: Set{Authority::Read}`, so
  `VM#check_risk_flow` checks a labelled path argument against the
  policy's `Read` rules. The three streaming reads declare no
  authorities, so the same path reaches them unchecked, and a policy
  that forbids it is bypassed by switching verbs. `lines.cr` and
  `bytes.cr` point to `stat.cr`'s comment, which describes both checks
  as applying. Fix: declare `Authority::Read` on all three, with a spec
  reaching each from a labelled source, as `read_spec.cr` does.

- **The grants loader silently ignores what it can't read.**
  Predicted by reading `legate/grants.cr` and
  `net_rule.cr`; no spec covers it. The same decision as the
  risk-flow policy entry above applies: a malformed policy should
  fail when loaded, not surface at run time. Fail-open cases first:
  1. A `net.hosts` mapping whose `methods:` is a scalar (`methods:
     GET`) or misspelt (`method: [GET]`) reads as empty, and empty
     means "inherit `net.methods`", so a rule meant to narrow to GET
     allows every grant-wide method, POST included.
  2. A per-run budget written as a YAML integer (`total_read:
     1048576`, `wall_clock: 300`) is read with `as_s?`, gets nil, and
     is not enforced. `SizeLiteral` accepts a bare byte count only as
     a string.
  3. A misspelt key anywhere (`total_raed:`, `limts:`) is ignored,
     so its budget or grant is simply absent.
  Fail-closed but silent: a malformed category reads as nothing
  granted (`string_array`); a non-numeric, zero or negative
  `max_open_streams` falls back to the default; a scalar `ports:`
  gives the default port; a non-boolean `subdomains:` or `local:`
  gives false. The fix is a strict loader: unknown keys, wrong types
  and invalid values raise ArgumentError, as a malformed size literal
  or net rule already does.

- **The scratch directory is readable by other local users.**
  Predicted by reading `legate/broker.cr`.
  `Broker#scratch_dir` names it with `File.tempname` under the shared
  temp directory and creates it with `FileUtils.mkdir_p`, whose mode
  is 0o777; under a typical umask of 022 that is 0o755, so on a
  multi-user POSIX host anyone can list and read what a script writes
  there. `mkdir_p` also succeeds on a path that already exists, so a
  directory (or symlink) planted at that name would be used as is;
  the name's random part is 32 bits from the default PRNG, beside the
  date and pid. The fix is `Dir.mkdir(dir, 0o700)`, which fails if
  the path exists, retrying with a new name on that failure.

- **Per-run budgets default to unenforced, and `wall_clock` misses
  pure computation.** Decided: every per-run budget
  gets a default, as the per-call limits have.
  1. `wall_clock`, `total_read` and `total_write` are nil when a
     policy omits them, which means not enforced (`Legate::Limits`,
     `ResourceLimits`). LEGATE.md §7's example values (300s, 4GiB,
     1GiB) are candidate defaults; the section should state whichever
     are chosen.
  2. `memory` is carried but enforced by nothing in Adjutant:
     `budget.cr` leaves it to the OS tier (cgroups, rlimit). Its
     default is advice to the host, and §7 should say so.
  3. `wall_clock` is checked only in `Adjutant::Broker#authorize`,
     before an effectful call, and in `Legate.grep`'s loop. A loop with
     no effects never reaches either, so `loop { x += 1 }` runs past
     any `wall_clock`. The VM's own `ExecutionLimits#instruction_limit`
     defaults to 0, unlimited. The fix is checking the wall clock from
     the VM's dispatch loop, every N instructions, alongside
     `instruction_limit`.

- **`Legate.read` and `Legate.grep` read files whole without a
  bounded read.** Predicted by reading the verbs.
  1. `Legate.read` checks `limit` against `File.info`'s size, then
     `read_content` allocates `file.size` as reported at open. A file
     that grows in between, such as an active log, is read whole past
     `limit`, and `record_read` counts the earlier size. A pseudo-file
     reporting size 0 (`/proc/...`) reads as "" without error.
  2. `Legate.grep` reads each file whole into memory (`read_lines`)
     with no size cap; its `limit:` counts matches. The byte budget is
     recorded after the allocation, so a large file is held before
     `total_read` can refuse it, and memory is enforced only by the OS.
  The fix is reading at most `limit + 1` bytes from the opened handle
  and deciding on what was read, counting those bytes; `grep` needs
  `read_limit` per file, or a streaming match with a bounded window
  for `context:`. `Legate.records(format: :csv)` has the same gap per
  row: `CSV::Parser` has no row or field cap, so an unterminated
  quoted field grows until `total_read` stops it, if one is set.

- **`Legate.grep` and `Legate.list` label results by the pattern's
  prefix, not by each file.** Predicted by reading the
  verbs. Both consult the policy once, for the glob's fixed leading
  directory (`Helpers.fixed_prefix`), and put that one label on every
  result. With `/work/secrets/**` High and nothing else under `/work`,
  `Legate.read("/work/secrets/key")` is labelled High, but
  `Legate.grep(/./, "/work/**/*")` returns the same lines labelled as
  `/work`, which is unlabelled, and they reach a network sink with no
  Ask or Reject. `list` has the same shape for names, sizes and
  mtimes. The fix is looking up each matched file's sensitivity
  (`RiskFlowPolicy#sensitivity_for`) and labelling, and asking or
  rejecting, per file, while keeping one audit record per call.

**The Ruby divergences follow**, Must Fix whatever their frequency.
Where an entry lists two remedies, rejecting the construct is always
acceptable, since it restores the subset.

- **A new name assigned inside a block becomes a global, not a
  block-local.** Predicted by reading `compiler.cr`; no
  spec or model has hit it. `Compiler#emit_store_name` emits
  `SetGlobal` when a block (or lambda, or `for` body, which compiles
  as a block) assigns a name no enclosing scope defines, so
  `xs.each { |x| t = x * 2 }` writes `t` into the interpreter's
  `@globals`. Unlike Ruby: `t` is still readable after the block
  (Ruby raises NameError); recursive calls whose blocks use the same
  name share one variable, so the script can run and answer wrongly;
  and `@globals` is shared across `Interpreter#eval` calls, so the
  name carries into later scripts in the session. Conversely, a
  `for` loop's variable is unreadable after the loop, where Ruby
  keeps it. DEVELOPMENT.md's Parser section describes the block rule
  as Ruby's, which it isn't. The likely fix is a block-local slot for
  a block or lambda, and a slot in the enclosing scope for a `for`
  loop's variable and body.

- **`and` and `or` bind tighter than assignment.** Predicted by reading
  `parser.cr`. `maybe_assignment` parses the right-hand side with
  `parse_expression(0)`, and `KwAnd`/`KwOr` have precedence 3 and 2, so
  `x = false or true` sets `x` to `true`. Ruby parses `(x = false) or
  true` and sets `false`: `and` and `or` sit below assignment. The idiom
  `x = fetch or raise "..."` is unaffected, but `ok = check and log` is
  not. The fix is stopping an assignment's right-hand side at
  `and`/`or`.

- **`rescue e` is accepted as `rescue => e`.** `parse_rescue_clause`
  treats a bare identifier after `rescue` as the binding, and the
  clause catches StandardError. Ruby evaluates `e` as the class to
  match, which raises TypeError at match time unless `e` holds a
  class. About twenty specs use the form (`control_flow.rb`,
  `exceptions_spec.cr`, `risk_flow_enforcement_spec.cr`, ...), so the
  fix is rejecting it with a diagnostic that names `rescue => e`, then
  rewriting those specs.

- **An Integer and an equal Float are the same Hash key.**
  `{5 => "a"}[5.0]` returns `"a"`; Ruby returns nil, since Hash keys
  compare with `eql?` and `5.eql?(5.0)` is false. `Value#==` and
  `Value#hash` delegate to the raw Crystal value, where `5 == 5.0`
  and the hashes agree. `hash_spec.cr`'s "cross-type numeric key
  lookup" asserts the current behaviour and must change with the
  fix. Hash keys need an `eql?`-style comparison: same type and
  value.

- **`Hash#each` with one block parameter binds the key alone.**
  Predicted by reading `hash.cr`; no spec or model has hit
  it. `h.each { |pair| }` gives `pair` the key, where Ruby gives
  `[k, v]`, so the script runs and answers wrongly. `Hash#each` passes
  `k` and `v` as two arguments. The likely fix is passing one
  `[k, v]` Array and letting `spread_block_args` (vm.cr) spread it for
  `|k, v|`, which is how Ruby does it.

- **An Array or Hash used as a Hash key is looked up by identity.**
  `{[1, 2] => "a"}[[1, 2]]` returns nil; Ruby returns `"a"`. A
  container key hashes and compares as the `LabeledArray` or
  `LabeledHash` reference, not by contents. The fix is hashing and
  comparing containers by contents, recursively, alongside the
  numeric-key fix above.

- **A leading-zero integer literal is decimal.** `0644` parses as 644;
  Ruby reads it as octal 420. `s.mode == 0644` compares against the
  wrong number without error. `0o`, `0x` and `0b` prefixes are also
  unsupported, which is only a gap. Scanning is in
  `Lexer#scan_number`.

- **Methods and lambdas don't check positional arity.**
  `VM#bind_args` leaves a missing positional argument nil and ignores
  extras, so `def f(a, b); end; f(1)` runs with `b` nil, where Ruby
  raises ArgumentError. The comment there claimed Ruby is lenient
  too; only blocks are. Lambdas must be strict as well: UNSUPPORTED.md's
  U019 entry describes `lambda`'s arity as strict, which it isn't
  yet. Keyword arguments are already checked (R011, R012).

- **Indexing shapes the VM doesn't handle return nil or do nothing.**
  `VM#exec_get_index` handles Array, Hash and String receivers and an
  object's native `[]`; everything else falls to nil. So `arr[1..2]`
  is nil, where Ruby slices (the skill tells models Arrays don't
  slice, but the runtime doesn't say so); `s[1..]` and `s[..2]` are
  nil, since a String range needs two Integer bounds; `nil[0]` and
  `5[0]` are nil, where Ruby raises NoMethodError or returns a bit.
  On the write side, `exec_set_index` ignores `arr[5] = x` past the
  end (Ruby pads with nil) and `arr[-9] = x` before the start (Ruby
  raises IndexError), and ignores every receiver but Array and Hash,
  so `s[0] = "x"` does nothing. Each shape needs Ruby's result or an
  error.

- **`break` outside any loop or block is ignored.** A `break` with no
  loop compiles to BlockBreak; in a method body with no block frame,
  `Op::BlockBreak` pushes the value and carries on. Ruby rejects it
  (SyntaxError, "Invalid break"). The compiler knows when no loop
  encloses a `break`, but not whether it is in a block, so the
  rejection may belong in the compiler's scope tracking.

- **`is_a?` misses a module included by an included module.**
  `VM#is_a_target?` checks each class's direct `included_modules`
  only, so with `module A; end; module B; include A; end; class C;
  include B; end`, `C.new.is_a?(A)` is false and `when A` doesn't
  match (`Class#===` uses the same check). Ruby says true. Searching
  `RubyClass#ancestors` would fix both.

- **Float `%` by zero raises ZeroDivisionError.** `ValueOps.mod`
  raises for a zero divisor of either type; Ruby raises only for
  Integer `%` and returns NaN for `5.0 % 0` and `5 % 0.0`. Float `/`
  by zero already returns Infinity, as in Ruby.

- **`equal?` is true for equal Strings, and `superclass` is nil on a
  non-class.** `exec_builtin`'s `equal?` compares values, so
  `"a".equal?("a")` is true; Ruby compares identity and says false for
  two String objects. Its `superclass` returns nil for any receiver
  that isn't a class, where Ruby raises NoMethodError (`5.superclass`).

- **Native methods don't check positional arity either.** A native
  method reads `args` directly, so extra arguments are ignored and a
  missing one takes whatever the method's own fallback is:
  `[1].include?` is false and `[1, 2].first(1, 2)` is `[1]`, where
  Ruby raises ArgumentError for both. Keywords are checked
  (`kwarg_names`, R012). The fix is declaring each native method's
  positional arity, required and optional counts, in its
  NativeCallable and checking it in `VM#call_native`, alongside the
  script-method fix above.

- **Blockless iterators return a value instead of an Enumerator.**
  `Array#each` without a block returns the receiver, and `map`,
  `select` and `reject` return `[]`, where Ruby returns an
  Enumerator. So `arr.map` is silently empty; `arr.map.with_index`
  fails only one call later. Adjutant has no Enumerator, so the fix is
  raising, as `sort_by` already does (R045), for every block-taking
  builtin method called without one. Audit `hash.cr`, `range.cr`,
  `string.cr` and `integer.cr` (`times`) for the same shape.

- **`Array#join` renders elements with Crystal's `to_s`, not the
  script's.** `join` calls `Value#to_s`, which renders a nested Array
  or Hash as `#<Adjutant::LabeledArray>` and ignores an object's own
  `to_s`. Ruby joins nested arrays recursively (`[1, [2, 3]].join(",")`
  is `"1,2,3"`) and calls each element's `to_s`. The fix is dispatching
  `to_s` through `ncc.call_method`, recursing into Arrays, as
  `inspect` already does.

- **`String#split` follows Crystal's rules, not Ruby's.** `split`
  calls Crystal's `String#split`, which keeps trailing empty fields:
  `"a,b,,".split(",")` is `["a", "b", "", ""]`, where Ruby gives
  `["a", "b"]`. A `" "` separator is literal, where Ruby treats it as
  a whitespace split (`"a  b".split(" ")` is `["a", "b"]`). A `limit`
  is passed to Crystal unchecked against Ruby's rules (positive caps
  the fields, negative keeps trailing empties), and is ignored for a
  whitespace split. CSV-style parsing, as in exam task 04, meets the
  first case.

- **`String#each_line("")` splits on newlines, not paragraphs.** Ruby's
  empty separator is paragraph mode, splitting on runs of blank lines;
  Adjutant falls back to `"\n"` without saying so.

- **Regexp and MatchData edge cases differ from Ruby.**
  `Regexp#match(nil)` raises R022, where Ruby returns nil, so
  `re.match(maybe_nil)` fails only in Adjutant. `MatchData#[]` with an
  unknown group name returns nil, where Ruby raises IndexError. And in
  a pattern with named groups, Ruby doesn't capture the unnamed ones,
  so `/(a)(?<b>b)/.match("ab")[1]` is "b"; PCRE2 numbers both, so
  Adjutant gives "a".

- **Methods Ruby doesn't have.** `Range#exclusive?` is registered
  alongside Ruby's `exclude_end?`; a script using it is not Ruby. The
  fix is removing it. Other builtins may carry similar extras: the
  whitelist check in `spec/skill/TODO.md` §3 lists every registered
  method, which is where to compare each class against Ruby's.

- **`include` and `extend` accept a class.** `mixins.cr` takes the
  argument's RubyClass without checking `is_module?`, so
  `include SomeClass` mixes a class's methods in, where Ruby raises
  TypeError ("wrong argument type Class (expected Module)"). A
  non-class argument fails in `as_rclass` as an internal error. Both
  should raise TypeError.

- **Quoted Symbol literals don't decode escapes.** `:"a\nb"` keeps a
  literal backslash and `n`. The Symbol is built in `parser.cr` by
  stripping quotes from the lexeme (`SymbolLiteral.new(tok.lexeme
  .lstrip(':')...)`) without `decode_string_escapes`, which string
  literals use.

- **A class's `self.inherited` is never called.** A script can define
  `def self.inherited(subclass)`, and Ruby calls it when the class is
  subclassed, before the subclass body runs; Adjutant never does, so
  a registry built on it stays empty without error. Either call it
  where `class Foo < Bar` links the superclass (`compiler.cr` and the
  VM's MakeClass), or reject its definition with a U-code.

- **A second heredoc opener on a line is lexed as `<<`.** `foo(<<~A,
  <<~B)` is valid Ruby. Only the first opener's body is skipped, so
  the second body's lines are lexed as code. The lexer resolves one
  opener per line (`Lexer#scan_heredoc_opener`). At minimum a second
  opener must be a parse error; full support means queueing the
  openers and reading their bodies in order.

- **`Array#inject`/`reduce` with a Symbol and no block returns `nil`.**
  Found by reading `builtins/array.cr`. `[1, 2, 3].inject(:+)` treats
  `:+` as the initial value and, finding no block, returns `nil`. Real
  Ruby returns `6`. Supporting the Symbol form means dispatching the
  named method; until then it should raise rather than return a
  plausible `nil`.

- **`respond_to?` is false for operations only `exec_builtin`
  handles.** `script_responds_to?` (`vm.cr`) checks the script and
  native method tables, as `dispatch_call` does, but not the operations
  `exec_builtin` implements itself. So `x.respond_to?(:to_s)` is false
  while `x.to_s` works; the case's own comment says so. No spec pins
  it. Fix: also accept `exec_builtin`'s public names (`to_s`, `inspect`,
  `class`, `is_a?`, `dup`, ...) from one list both use. Its Kernel
  names (`puts`, `print`, `p`, `raise`, `require`) must stay false, as
  they are private in Ruby.

- **`dup` and `clone` of a Time, Regexp, MatchData, Stream or Chunk
  return an object without its state.** Found porting mruby's
  `Time#initialize_copy` test (`spec/scripts/mruby/time.rb`). The
  `"dup", "clone"` case in `exec_builtin` (`vm.cr`) allocates
  `RubyObject.new(obj.rclass)` and copies `ivars`. That is right for a
  script's own class, but `TimeObject`, `RegexpObject`,
  `MatchDataObject`, `Legate::StreamObject` and `Legate::ChunkObject`
  keep their state in typed fields. The copy has the right class and
  none of the state, and the first method that reads it fails with an
  internal cast error (`Cast from Adjutant::RubyObject to
  Adjutant::TimeObject failed`). Fix: a virtual copy method on
  `RubyObject`, overridden by each subclass, called before
  `initialize_copy`. A Stream needs its own decision, since the copy
  and the original would share one open source.

- **A risk-flow rule can't name the sink's subject.** `RiskFlowRule`
  (`risk_flow_policy.cr`) is keyed on `(Authority, Sensitivity)`, so a
  policy can say "High data must not reach `Net`" but not "this API
  key may reach `api.stripe.com` and nowhere else". A credential from
  `Legate.env` reaching its own server is the normal case, so today a
  policy must either reject it everywhere or allow it to every granted
  host. The grants can't help: `net` rules say which hosts may be
  reached, not which data. `Broker#authorize` receives the subject (a
  path or host) but uses it only as the label's origin, and
  `VM#check_risk_flow`, which checks the data arguments, has no subject
  at all; a verb would have to say which argument is its subject. Fix:
  an optional subject pattern on the rule, reusing
  `SensitivityPattern`'s exact and regex matching. Two questions first:
  whether an absent pattern means "any subject", which is convenient
  but makes every rule without one broader than those with one, and
  which subject a rule sees when `fetch` follows a redirect.

- **Authorization is in core, but its configuration and the specified
  static analyser still assume one provider.** The perimeter
  (`grants.cr`), run accounting (`ResourceLimits`, `Budget`,
  `OpenSources`, `FatalSignal`) and the checks every call passes
  (`Broker#authorize`, `broker.cr`) are core, and `Legate::Broker` is
  the one `EffectProvider`. What remains needs a registry of providers,
  which doesn't exist: core never routes a call, so dispatch doesn't
  need one, but anything that iterates providers does.

  1. **One configuration document.** Grants are YAML
     (`Legate::Grants.from_yaml`) and the risk-flow policy is JSON
     (`RiskFlowPolicy.from_json`), though a host writes them as one
     policy. Each provider should contribute and parse its own
     section. The merge must keep three properties: no permissive
     default (a document with grants and no risk section means
     `reject_all`, and the reverse likewise); Adjutant reads no policy
     from disk, the host passes it; and every `Authority` stays
     covered, since a larger document has more places to omit one.
     This is the one piece that changes an embedder-facing format,
     which is why it is Must Fix before 1.0.
  2. **LEGATE.md §10.1 keyed on providers.** Its grant inference
     collects `Legate.*` calls. Built as written, a second provider
     would be enforced at runtime and missing from the manifest.
     Suppose a `Vault` provider and this script:

         key = Vault.secret("stripe/live")
         Legate.fetch("https://api.example.com", body: key)

     At runtime it is fully checked, since `Vault` goes through the
     same `Broker`. Statically, the inferred policy mentions only
     `net`, the offered `vault:` grant looks like an over-grant, and
     the manifest reports a network request but not the credential
     read before it. The spec should say the walk collects calls to
     every registered provider, each mapping its verbs to the
     authorities it declares (`EffectProvider#authorities`).
  3. **LEGATE.md §7's ownership.** It specifies the policy file, most
     of which is now core. Either move it to a core document or state
     that it describes Legate's surface over a core mechanism.

  `Authority` stays a closed enum: it keys `RiskFlowRule`,
  `RiskFlowPolicy.reject_all` must cover every member, and the
  manifest's vocabulary must not depend on which providers are loaded.
  There is no second provider today, so this generalises on the
  argument rather than on evidence.

## Will Fix

Real gaps, not currently blocking anything, no active design conversation
yet. Promote to `Must Fix` when something starts depending on it.

Grouped by capability so adjacent work is easy to spot — within a group,
still roughly ordered by how cheap/independent the fix is.

### Parser / lexer gaps

Small, mechanical, independent of each other — good candidates for quick
wins.

- **`defined?` and `Module#const_defined?` don't exist.** Found in the
  mruby sweep (`test/t/syntax.rb`, `spec/scripts/mruby/float.rb`).
  `defined?` lexes as an ordinary method name (`lexer.cr`), so
  `defined?(x) ? x : default` raises instead of answering. It needs a
  keyword, parser support, and a check per operand kind: expression,
  `self`, local, method and constant (globals are excluded, U011).
  `Object.const_defined?(:Float)` is separate work, an ordinary native
  method.

- **Leading-dot line continuation for a method chain isn't supported**
  (`obj\n  .method\n  .method` — real Ruby 1.9+ syntax) — raises P002
  (`.` can't start an expression here) rather than parsing. Found
  2026-08-24 writing a multi-line `Legate::Stream` chain spec.
  Genuinely common, readable Ruby style for a chain of 3+ calls, and
  the kind of thing an LLM trained on real-world Ruby would reach for
  by default — worth fixing since a script author hitting this gets a
  parse error on ordinary-looking code, not silent wrongness, but
  still a real everyday-syntax gap.

- **`%W[]`/`%I[]` (interpolating word/symbol arrays) and `%q`/`%Q`/`%r`
  (the general delimited-literal forms) aren't supported — only plain
  `%w[]`/`%i[]` are.** Added 2026-08-19 alongside `%w[]`/`%i[]` itself
  going in for the first time (see `DEVELOPMENT.md`'s "The Lexer"
  writeup) — a deliberate scoping decision, not a later-discovered
  gap: `%w[]`/`%i[]` cover the common "word array"/"symbol array"
  idiom the Must Fix entry was written against, and the interpolating/
  general forms are rare enough in practice to leave for whoever wants
  a follow-up. Mechanically similar to add: `%W`/`%I` would need the
  word-splitting step to also watch for `#{...}` per word (closer to
  the heredoc interpolation path than the plain `%w` one), and `%q`/
  `%Q`/`%r` are just `'...'`/`"..."`/`/.../ ` with an arbitrary
  delimiter instead of the fixed one.

- **A bare `next`, `break` or `return` directly before `}`, `end` or
  `else` probably fails to parse.** Predicted 2026-09-24 while fixing
  the modifier `if`/`unless` case; not yet confirmed by a spec or a
  model. `jump_value_follows?` (parser.cr) treats only a newline, `;`,
  end of file and a modifier `if`/`unless` as "no value here", so in
  `items.each { |x| next }` or `if a then break end` the parser tries
  to read `}` or `end` as the keyword's value. Ruby accepts both. The
  likely fix is adding `RBrace`, `KwEnd` and `KwElse` to that list,
  once a failure confirms it.

- **`&:symbol` proc-shorthand (`arr.map(&:length)`) isn't supported —
  `&` can't start an expression there at all (P002).** Found
  2026-08-26 writing a `Legate.lines` spec, reaching for
  `.map(&:length)` out of habit and hitting a hard parse error rather
  than a wrong answer. Common enough to matter: it's arguably THE most
  reached-for block shorthand in idiomatic Ruby, ahead even of a
  one-line `{ |x| x.foo }`, for exactly the "call one method on every
  element" shape that turns up constantly in `Legate::Stream` chains
  (`.select { }.map(&:foo)`-style code) — an LLM writing natural Ruby
  will reach for this by default, same "everyday syntax block" bar
  the leading-dot-chaining entry above was promoted on. Likely lands
  as sugar at the parser/AST level: `&:name` desugars to the same
  shape as a literal `{ |x| x.name }` block/`Proc` (real Ruby's
  `Symbol#to_proc`), so — depending how block-arg-passing is
  structured today — this may be closer to "recognize `&` followed by
  a Symbol literal and synthesize the equivalent block AST node" than
  new runtime machinery. Not yet traced to the exact parser callsite
  (wherever `&blockarg` is currently parsed at a call site) or
  confirmed whether `Proc`/`Symbol#to_proc` already exist as a target
  to desugar onto.
  `ensure` treatment `def` bodies just got?** Open question, not a
  confirmed gap — flagged 2026-08-10 when `def`'s own version shipped
  (see `DEVELOPMENT.md`'s "Method-body (implicit) rescue" section).
  Real Ruby's grammar treats `def`, `class`, `module`, and top-level
  program bodies uniformly as an implicit `begin` ("bodystmt") — so
  plausibly yes, `class Foo; risky; rescue; end` is valid Ruby too —
  but this hasn't actually been confirmed against real Ruby the way
  the `else`-without-`rescue`/duplicate-`else` behaviors were
  (`irb`-confirmed, see `parse_begin_else`'s own comments). If
  confirmed, the fix is likely the same shape `parse_def`'s just used
  — `parse_class`/`parse_module` (`parser.cr`) wrapping their own
  parsed body in a synthetic `BeginNode` via the same
  `parse_rescue_else_ensure` helper, reusing the identical
  compile/runtime path with no new compiler or VM work either.

- **`obj.attr += 1` / `obj.attr ||= x` / `obj.attr &&= x`** — compound
  and conditional assignment through an attribute-setter call. Found
  2026-08-08 landing plain `recv.attr = value` (the new `AttrAssign`
  node, ast.cr/parser.cr/compiler.cr/vm.cr — see `DEVELOPMENT.md`'s
  Parser section for the full trace). `Parser#maybe_assignment` only
  builds `AttrAssign` for its plain-`=` branch; the `PlusEq`/`MinusEq`/
  .../`OrAssign`/`AndAssign` branches immediately below still build an
  ordinary `OpAssign`/`CondAssign` with the `Call` as `target`, which
  `Compiler#emit_store`'s generic per-target-kind dispatch has no case
  for — falls to the same `C001` ("cannot assign to a method call") it
  always has. Not simply a matter of adding an `emit_store` `Call`
  case the way `Index`'s case already exists: `OpAssign`/`CondAssign`
  both read the target ONCE (`compile_node(node.target)`, at the very
  top of `compile_op_assign`/`compile_cond_assign`) before computing
  anything — for a `Call` target that means calling the GETTER — and
  then need to call the SETTER afterward with the combined result,
  which means the receiver expression needs evaluating exactly once
  and reusing (not recompiling) for both the getter and setter calls,
  the same single-evaluation requirement `AttrAssign` was built to
  satisfy for plain `=`. Needs a dedicated desugar/AST shape of its
  own (something that computes the receiver once, calls the getter
  off a stack-held copy, computes the op, then calls the setter off
  the SAME copy) — a genuinely different shape from `AttrAssign`, not
  a small extension to it.

- **Call-site splat/double-splat expansion (`foo(*args)`,
  `foo(**opts)`), and `def foo(...); bar(...); end` argument-forwarding
  shorthand.** Def-site `*args` collection already works; what's
  missing is *spreading* an existing array/hash back out at a call
  site — needed for delegation/wrapper patterns ("call this other
  method with whatever I was given"), a common shape in agent-
  generated code. Not yet traced to specific parser/compiler locations.
  The `...` forwarding shorthand (found 2026-08-05 in the mruby
  full-repo sweep, `test/t/syntax.rb`'s "argument forwarding") is
  real Ruby 2.7+ sugar over the same underlying capability — once
  call-site splat/double-splat exists, `...` is a terser spelling of
  `(*args, **kwargs, &blk)`, not a separate mechanism; worth
  implementing together or `...` shortly after, not as an independent
  design question.
- **`raise`/`super` don't get the same space-before-`(` fix
  `parse_identifier_or_call` got.** Flagged 2026-07-26 while fixing
  `eq (6/3), 2` (see `DEVELOPMENT.md`'s Parser section) — `parse_raise`
  and `parse_super` (`parser.cr`) both still have the identical
  unconditional `if at_kind?(TokenKind::LParen)` pattern that bug was
  in, so `raise (x), y`-shaped code would misparse the same way.
  Deliberately not fixed alongside the reported bug (would have
  silently widened that session's scope); pick up using
  `Token#space_before?` the same way `parse_identifier_or_call` does,
  if ever actually hit.
- **`for`/`while`'s do-ambiguity fix pattern not applied elsewhere.** The
  `@no_do_block` suppression flag (parser.cr) fixing `for x in a do`/
  `while cond do` mis-parsing was scoped to those two constructs. The
  same shape of bug (`block_follows_no_paren?` mis-firing on a bare
  identifier immediately before a construct's own `do`) was flagged as
  likely present in `parse_until`/anywhere else accepting an optional
  trailing `do` — not verified beyond `while`/`for`.

Symbol-shorthand hash literal syntax (`{k: v}`) — same underlying gap
as originally filed here — was promoted to `Must Fix` 2026-08-05 and
shipped 2026-08-08 (`Parser#parse_hash_key`/`#label_follows?`,
parser.cr). See DEVELOPMENT.md's hash-literal note for the final
shape.

### Verified only up to compile time, never actually run

Constructs the parser and compiler both have real, non-trivial code
paths for, but with zero test coverage that actually executes them
through the VM — so "does this work" is currently an assumption, not a
checked fact. Worth taking seriously as its own category rather than
folding into ordinary missing-feature gaps: this exact shape (a
complete-looking implementation nobody had ever actually run) is
precisely what `redo`'s `LoopScope#body_pos` bug and
`compile_modifier_while`'s check-last-for-everything bug both turned
out to be, found 2026-08-06 only because that session's fix happened
to need a test that finally exercised them. Nothing here is *known*
broken — only unconfirmed, which the pattern above suggests is not the
same as fine.

Empty as of 2026-08-06 — `case`/`when` was this category's one
remaining entry (found earlier the same day, no VM-level test anywhere in the
repo despite a real, seemingly complete `compile_case`), and this
session's `===` work closed it properly: `control_flow/vm_spec.cr` now
covers literal matching, `else` fallthrough, `Class#===`, `Range#===`
(inclusive and exclusive), and the plain-`==` fallback. Confirms the
category's own framing was right to take seriously — this wasn't
"probably fine," it was hiding the exact `===` fallback bug the
adjacent `Must Fix` item existed to fix, undiscovered specifically
because nothing had ever run it.

### Error reporting

- **Runtime diagnostics have a line but no column, so no caret.** The
  AST carries columns, but `Instruction` (`bytecode.cr`) and `Frame`
  (`vm.cr`) record only a line. On a dense line (`foo(bar.baz, qux[i])`)
  the reader can't tell which call failed. A column on every
  instruction costs memory per instruction; a table from instruction
  index to column, filled only where the compiler emits a call, may be
  cheaper.

- **`ParseError` and `CompileError` keep a message-only constructor
  nothing uses.** Every raise site in `parser.cr` and `compiler.cr`
  builds a `Diagnostic`; `ParseError.new(message, line, column)` and
  `CompileError.new(message, line, column)` are reached only by
  `diagnostic_spec.cr:172`. `HostStateError.new(message)`
  (`diagnostic.cr`) likewise has only a spec caller. Removing them
  makes `diagnostic` non-nilable on those classes and lets callers
  drop their nil handling. `InternalError.new(message)` is still used
  and stays.

- **U008, U009, U012–U015 and U021 are decided but not enforced.**
  See `UNSUPPORTED.md` for each. Using one falls through to a generic
  undefined-name, undefined-method or parse error that doesn't name
  the construct, the failure shape `UNSUPPORTED.md`'s second principle
  forbids. U021 costs the most in practice: a model reaching for
  `File.read` or `ENV` is told the constant is uninitialized, not that
  `Legate.read` or `Legate.env` is the way. Enforcing U021 is mostly
  entries in `ErrorCatalog::EXCLUDED_CONSTANTS` (`File`, `ENV`, ...)
  and `EXCLUDED_METHODS` (`system`, `exec`, ...), which are consulted
  only after resolution fails. U008, U009 and U021 are
  lookup-after-resolution-fails checks, the mechanism U005–U007 use
  (`dispatch_call` and constant resolution, `vm.cr`); U012–U015 fail
  in the parser today, so each needs its own enforcement point.
  Backticks and `%x{}` have no case in the lexer at all, so theirs is
  there.

- **U007's reflection exclusion is a category, not a list, so only
  `ObjectSpace` is enforced.** Added 2026-07-29 while enforcing U005–U007.
  `UNSUPPORTED.md`'s U007 entry describes "arbitrary FFI,
  `ObjectSpace`-style introspection, and similar" — a shape rather than an
  enumerated set. `ObjectSpace` could be enforced because it is named;
  everything else reflective (`binding`, `methods`, `instance_variables`,
  `instance_variable_get`, and so on) still reports as an ordinary
  undefined name.

  Deliberately not enumerated during that work: deciding which names are
  permanently excluded is a scope decision, and making it while writing
  the enforcement would have settled it by implementation rather than by
  choice. The same applies to `class_eval`/`module_eval`/`instance_exec`
  under U006 — the same hazard as `eval`, but not currently declared.

  Worth a short scoping conversation to settle both lists, after which
  enforcement is a one-line table addition each.


Quality-of-diagnostic gaps in the `Diagnostic`/`ErrorCatalog` system
(see [ERRORS.md](./ERRORS.md)). None affect correctness — every one is
"the error is right, but says less than it could."

- **`@def_depth` counts nesting but doesn't record what the enclosing
  scope was, so U004 can't name it.** Added 2026-07-28 while migrating
  U004 to a diagnostic. The guard in `Compiler#compile_def` fires on
  `@def_depth > 0`, which is enough to know a `def` is nested inside
  *something* deferred but not whether that something was a `def` or a
  lambda, nor its name. The message therefore says "inside another
  method's body" generically, where it could say "inside method
  `foo`" and point a secondary span at `foo`'s own definition —
  materially more useful when the two are far apart in a long file, or
  when the nesting was accidental.

  The fix is to make `@def_depth` a small stack of
  `{kind, name, line, column}` rather than an `Int32`, threaded
  through `compile_proc` the same way the counter already is. Depth
  then becomes the stack's size, so the existing guard condition is
  unchanged. Deliberately deferred when U004 was migrated: it turns a
  counter into a data structure across every `compile_proc` call site,
  which is a wider change than the migration it would have ridden
  along inside.

  Would also give U004 its first real use of a secondary span, which
  nothing exercises yet.

### Object model

- **Bracket indexing (`obj[i]`) on a custom/native-backed `RubyObject`
  now calls a NATIVE `[]` method for real — fixed 2026-08-14 — but a
  SCRIPT-DEFINED `[]` still can't be reached via `obj[i]` bracket
  syntax at all.** Found while wiring up `MatchData#[]`
  (`builtins/regexp.cr`): `exec_get_index`/`Op::GetIndex` was a fixed
  case statement covering only Array/Hash/String, with everything
  else falling straight to a silent `Value.nil_value` — a real
  silent-wrong-answer bug (the exact category worth staying alert
  for), not a raised error: `MatchData#[]` was registered correctly
  and simply never reached, no matter what it returned. Fixed via
  `exec_get_index_fallback` (`vm.cr`), which now calls a receiver's
  own native `[]` method via `call_native`, the same synchronous path
  `dispatch_call`'s ordinary receiver branch already uses for `.foo`
  calls.
  **Deliberately still open:** a SCRIPT-defined `[]` (`find_method`,
  not `find_native_method`) still isn't handled — `call_script_proc`
  pushes a new VM frame and relies on the normal `Op::Call`/`Op::Ret`
  dispatch loop to resume and deliver the result later, which
  `exec_get_index_fallback` (called synchronously from inside a
  single opcode's handler) has no mechanism to wait for. Low practical
  urgency today: `def [](i)` can't even be WRITTEN in script yet
  either way (see `UNSUPPORTED.md`'s U017 note — no combined `[]`
  lexer token, so `parse_def` trips on the stray `]` first) — so only
  native `[]` methods exist to reach at all right now, and this fix
  already covers every one of those. Worth a real fix (likely
  restructuring `Op::GetIndex` to push a frame and let the normal
  dispatch loop resume it, same shape as any other deferred script
  call) once/if `[]` becomes script-definable.
  `Op::SetIndex`/`exec_set_index` (the `obj[i] = v` write side) has
  the exact same shape of gap and was NOT touched by this fix — flagged
  here rather than silently assumed fixed alongside the read side.

- **`Op::Mul` (and `%`) still doesn't dispatch to a `RubyObject`'s
  own `*` — only `+`/`-`/`/` do now.** Added 2026-08-23 alongside a
  real `Time` builtin (`builtins/time.cr`) that needed `t + 60`/
  `t - 60` to work via ordinary infix syntax: `VM#exec_add`/`#exec_sub`
  (`vm.cr`) check whether the LEFT operand is a `RubyObject` with its
  own `+`/`-` (native or script) before falling through to
  `ValueOps`'s base-type handling — the same "left receiver's method
  wins when it has one" shape `<=>`-derived `<`/`<=`/`>`/`>=`/`==`
  already established. Widened same-day to `/` too (`VM#exec_div`) —
  `Legate::Path#/` (`legate/path.cr`, LEGATE.md §5.1) needed real
  infix `/` to work the moment Path's own spec was implemented, not
  just theoretically anticipated the way `*`/`%` still are.
  DEVELOPMENT.md's own "Some operators are overloaded across base
  types" section originally anticipated this whole gap for `-`/`*`/
  `/` and explicitly said to close each "if [something] does" need
  it; `Time` was that something for `+`/`-`, `Legate::Path` for `/`.
  `*`/`%` remain untouched — nothing needs them yet either — so this
  stays Will Fix rather than Must Fix; promote if a future type needs
  one.

- **No `Numeric` ancestor class in the `RubyClass` hierarchy, so
  `5.is_a?(Numeric)` fails rather than returning `true`.** Long-
  standing, untriaged since the original 2026-07-14 handoff bundle —
  reworded 2026-08-10 on review: the previous framing implied this
  silently returns a wrong answer, which isn't what actually happens.
  No class named `Numeric` is registered anywhere (`grep` confirms),
  so referencing it at all fails at constant resolution first — a
  clean, loud `R006` (undefined constant), not a silent `false`. Real
  gap, genuinely missing feature, but the loud-failure kind rather
  than the incorrect-in-normal-use kind. Narrowed 2026-08-06,
  separately from this rewording: `<=>` itself already works for
  `Integer`/`Float`/`String` (`ValueOps.spaceship`, `exec_builtin`'s
  `"<=>"` case), which was this item's original practical motivation
  and is no longer the gap — what's left is specifically the
  class-hierarchy piece.

- **Bare `new` (implicit `self`, no explicit receiver) doesn't
  dispatch inside a class method.** Found 2026-08-10, writing test
  coverage for the method-body-rescue fix — `def self.run; c = new;
  ...; end` raises `R008` ("undefined method or variable `new`"),
  while the exact same call written as `ClassName.new` works fine.
  `VM#dispatch_call`'s explicit-receiver branch has its own hardcoded
  `if recv.rclass? && name == "new"` special case for object
  construction — the implicit-self branch (self already IS the class,
  inside a class method) walks `find_singleton_method`/
  `find_native_singleton_method` normally instead, and `new` isn't
  actually registered in either of those tables; it only exists as
  that explicit-receiver special case. Not yet traced further than
  that — likely needs the same special-casing mirrored into the
  implicit-self branch, or `new` registered as a real native singleton
  method both branches would find the same way.

- **Top-level `extend` doesn't work — deliberately still excluded,
  not yet a real gap fix.** Bare top-level `include M` shipped
  2026-08-16 (see `DEVELOPMENT.md`'s "Bare `include` at the top level
  of a script" writeup for the full build-out) — this item is the
  narrower remainder, `extend` specifically, left out of that work on
  purpose rather than folded in. Confirmed against real `irb`:
  top-level `extend M` writes to a genuine PER-OBJECT singleton class
  belonging to `main` alone — `Object`'s own ancestors stay untouched,
  sibling `Object.new` instances are unaffected, and `Object.foo`
  doesn't pick up the extended method either (all three behaviors
  confirmed directly, not inferred). `RubyObject` has no storage for
  a per-instance singleton method table at all today — only
  `RubyClass` carries one (`singleton_methods`/`extended_modules`) —
  so `extend`'s existing mechanism (`RubyClass#extend_module`,
  consulted by `find_singleton_method`/`find_native_singleton_method`)
  has nowhere correct to target from `main`: writing into `Object`'s
  own `extended_modules` would make `Object.foo`-style calls work
  (wrong — real Ruby doesn't) while leaving bare calls at the top
  level unaffected (also wrong — that's the actual goal), the exact
  opposite of what's needed. Fix shape, if taken on: give `RubyObject`
  a genuinely new field (a `singleton_methods`/native counterpart,
  `nil` for every object except `main`), and a new lookup step in
  `dispatch_call`'s implicit-self `RubyObject` branch — checked BEFORE
  `cls.find_method`, matching the real `irb`-confirmed resolution
  order (`self.hello` found the extended method ahead of anything
  `Object` itself could offer) — gated on `self_val.same?(interp.main)`,
  the same restriction the shipped `include` fix already uses. Real,
  separate plumbing, not a small addition to the `include` mechanism —
  worth its own session rather than a quick follow-on.

Per-instance singleton methods became a deliberate non-goal 2026-07-27
(see [UNSUPPORTED.md](./UNSUPPORTED.md), U004). Implicit-`self`
privacy/visibility (`private`/`public`/`protected`) became a deliberate
non-goal 2026-08-05 (see UNSUPPORTED.md, U008) — this remains true for
visibility as a general, declarative feature; top-level `def` shipped
its own narrow, always-on private treatment 2026-08-16, not a
reopening of that decision (see DEVELOPMENT.md's "Top-level `def` is
implicitly private" writeup for the distinction). `Class.new(kwargs)` →
`initialize` binding was promoted to `Must Fix` 2026-08-05 and has
since shipped (see git history/`DEVELOPMENT.md`'s "Argument binding"
section).


### Data & builtin types

- **`Array` has no `#count` at all** (`#length`/`#size` exist, `#count`
  doesn't — checked `array.cr` directly). Found 2026-08-24 writing a
  `Legate::Stream` spec that called `.to_a.count` out of habit. Real
  Ruby's `#count` is `#size`'s more common spelling in idiomatic code
  and also overloads to count matching elements (`#count { }` /
  `#count(x)`, unlike plain `#size`) — worth adding both the bare
  alias and the block/argument forms together rather than just the
  alias, since an LLM reaching for `#count` is at least as likely to
  want the filtered form.

- **A TypeError from a binary operator renders nil as nothing at
  all.** Found in the same round: a model's `counts[word] + 1` on a
  missing key reported `cannot add  and 1`, because `ValueOps` builds
  the message with `#{a}` and `Value#to_s` of nil is the empty string.
  The gap in the message is where the answer is. `#{a.inspect}` gives
  `cannot add nil and 1`; R013's data already uses `inspect` for
  exactly this reason.

- **`Integer`/`Float` are both missing `#divmod`.** Found 2026-08-13
  triaging `spec/scripts/mruby/float.rb`'s commented-out `Float#divmod`
  block. Real Ruby's `#divmod` returns `[quotient, remainder]` as a
  single call — `/` and `%` already work individually (opcode-level,
  `ValueOps.div`/`.mod`) so this is purely a convenience wrapper
  around two things that already work correctly on their own, not a
  new arithmetic primitive. Lower priority than the other Data &
  builtin types entries here — no known common idiom depends on it
  the way `Integer#times` or `Array#first` did.

- **`Range` beyond `Integer` (and whatever else has a working
  `#succ`) — String ranges, custom-object ranges — isn't supported.**
  Long-standing, untriaged since the original 2026-07-14 handoff
  bundle — split out 2026-08-10 on review. `Range#each`'s advance
  mechanism (`vm.cr`, the `#succ`-calling case) is already generic
  over anything with a working `#succ`, not hardcoded to `Integer` —
  so this narrows to whatever's still missing beyond that (bound-type
  validation at construction, `#include?`/`#cover?` for non-`Integer`
  bounds, string ranges specifically since `String#succ` needs its
  own char-advance logic Ruby has and Adjutant may not). Not yet
  traced further than that — worth confirming exactly which piece is
  missing (a quick `("a".."e").each` test) before scoping the fix,
  rather than assuming the whole feature is absent when `#each`'s own
  mechanism already generalizes.

- **String repetition** (`"ab" * 3`). `ValueOps.op` (the method backing
  `*`, see `value_ops.cr`) has real `Integer`/`Float` cases but no
  `String` one — `+`, `==`, and `<`/`<=`/`>`/`>=` all DO already work for
  strings at the opcode level (see `ValueOps.add`/`.equal?`/`.compare`),
  so this is narrowly about `*` specifically. Noticed while bootstrapping
  the `String` builtin class (Phase 4a of base types); out of scope there
  since that work only wires up native METHODS, not opcodes.

- **`dup`/`clone` on a builtin-kind receiver** (Integer, String, Array,
  Hash, Symbol, true/false/nil, ...) raise `NoMethodError` rather than
  copying. Found 2026-08-08 landing `dup`/`clone` for RubyObject
  receivers (`exec_builtin`'s new `"dup", "clone"` case, vm.cr) — a
  RubyObject copy is a clean shallow-`ivars`-copy question, but a
  builtin receiver isn't: real Ruby returns the receiver itself for a
  true immediate (Integer, Symbol, true/false/nil) but an independent
  copy for String/Array/Hash, and Adjutant's `Value` model can't yet
  tell two separately-boxed instances of the same collection apart at
  all — the exact identity gap the entry above and `equal?`'s own
  comment (vm.cr's `exec_builtin`) already document. Matching only the
  immediate half of that split would be actively wrong for the other
  half, so both were left raising rather than half-implemented.
  Depends on (or at least belongs right alongside) resolving that
  underlying content-vs-reference identity question, not a fix of its
  own.




Carried forward from the original 2026-07-14 handoff — the oldest items,
undesigned rather than merely unimplemented, more product-shaped than
bug-shaped. Worth a dedicated design pass rather than picking off
individually.

- **No structured audit-trail export beyond `RiskFlowLog` itself.**
  Nothing turns a `RiskFlowLog` into a saved/replayable session record.
- **The approval cache** (avoid re-prompting for an already-approved
  origin→sink flow within one script run) — still not designed.
- **Eager vs. lazy ambiguous-priority policy validation** for
  `RiskFlowPolicy` — still not decided.

### Standard library surface

- **`catch`/`throw` (Kernel non-local jump, tagged block).** Found
  2026-08-05 in the mruby full-repo sweep — mruby packages this as an
  optional gem (`mruby-catch`) rather than core language, which is the
  right call for Adjutant too: `catch`/`throw` are `Kernel` methods in
  real Ruby, not keywords, so nothing about the language grammar needs
  to change. Buildable as a native module on top of the exception
  machinery already built for `raise`/`rescue` (a tagged non-local
  jump is structurally close to a targeted raise) rather than needing
  new opcodes — natural fit for the core-API-library work rather than
  a standalone language-layer item. Filed here rather than under a
  language-gap group for that reason.
### Streamed fetch on Windows

- **A script that raises inside a streamed `Legate.fetch` walk
  terminates the host process on Windows.** Found 2026-09-04 via CI.
  Exit `0xC0000409` — a fail-fast during exception unwinding, aborting
  inside MSVC's `FindAndUnlinkFrame`, which is an integrity check on
  the registered SEH frame list. Uncatchable by construction: it fires
  before any handler, and rescuing every exception changes nothing.

  **Believed to be a Crystal runtime defect rather than an Adjutant
  one**, on this evidence. Each of the three ingredients passes alone
  and only the combination dies: a raise unwinding through VM frames
  is fine (`begin_rescue_ensure/vm_spec.cr`), the same shape over a
  FILE-backed stream is fine (`open_sources_spec.cr`'s "closes a
  stream whose walk raised"), and cancelling a socket-backed stream
  without unwinding is fine (a `break` instead of a `raise`). It
  reproduces on Crystal 1.20 and latest, and does NOT need the test's
  in-process server — it crashes just the same against a static file
  server in another process, so it reaches real deployments rather
  than only the harness. Six standalone reproductions were attempted
  and none crashed; the trigger needs something structural the VM
  supplies that a small program does not.

  `verbs/fetch_stream_spec.cr`'s "closes the connection when the
  script raises mid-walk" is `pending` under `flag?(:windows)` —
  skipped, not deleted, so the coverage returns when the runtime is
  fixed. **Windows is therefore not a supported host for streamed
  `fetch`.** Buffered `fetch` was never tested and may or may not be
  affected. Not blocking on macOS or Linux, which is where the early
  access work is aimed.

  Parked deliberately: there is no sound fix available in this repo,
  and the investigation has already cost more than the platform is
  currently worth. To pick it up, the route that worked was cutting
  DOWN from the crashing spec, not building UP from a small program.

### Static risk assessment

- **A `RiskChoice` reports its worst branch, so effects reachable only
  on a losing branch vanish from the manifest entirely.** Found
  2026-09-04, while writing the step 4c sweep — the first draft of its
  end-to-end assertion assumed a union and failed, which is how the
  behaviour surfaced. `RiskAggregator.summarize_choice`
  (`risk_aggregator.cr`) takes `max_by { rank }` across branches: one
  summary wins whole, and the others contribute nothing.

  **The reasoning is sound for severity and does not obviously extend
  to effects.** Exactly one branch of an `if` runs, so reporting the
  worst `Severity`/`Reversibility` is honest where unioning them would
  overstate how bad a single run can be. But `rank` orders by those
  two fields alone, and both are CONCLUSIONS drawn from effects — so
  the effect SET is carried along by whichever branch happened to win
  on other grounds, rather than being reasoned about at all. Where two
  branches rank equally the tie goes to the first, which makes the
  reported effects a function of source order.

  The concrete case, now pinned in
  `spec/adjutant/legate/risk_assessment_spec.cr`: a script whose
  `else` branch calls `Legate.rmdir!` reports `NetworkEgress` and
  nothing else, because the `if` branch's `Legate.fetch` ranks equal
  and comes first. A user reading that manifest before running the
  script is not told a recursive delete is reachable.

  **The likely shape of a fix is worst-rank-with-full-effect-union** —
  keep the current severity and reversibility semantics exactly, union
  the effects across branches. That answers both questions the
  manifest is actually asked ("how bad can one run be" and "what could
  this script touch") without conflating them. Two things to check
  before assuming it is that easy: `RiskSummary#path` currently
  describes a single winning branch and would need to say something
  coherent about effects that came from elsewhere, and
  `summarize_deferred`/`RiskUnresolved` already deliberately over-
  report on the "can't confirm, surface loudly" principle — which
  points the same way, and is worth reconciling explicitly rather than
  by coincidence.

  Related to the provider work in Must Fix's authorization entry,
  whose `Vault` example is a manifest going silent while enforcement
  keeps working; this is the same failure by a different route.
  Not blocking anything today — the static pass is advisory, and
  runtime enforcement is unaffected, since `VM#call_native` fires from
  the call itself regardless of AST position.

- **LEGATE.md §10's static analyser isn't built.** No grant
  inference, exception gate, inclusion ledger or raise-set inference
  exists, and `risk_walker.cr` doesn't mention Legate. Nothing depends
  on it for safety: §9.2's fatal tier is uncatchable at runtime
  whatever the analyser does. Building it starts with a design
  question, what the "effectful surface" is. §10.4 counts 19 verbs
  (§4.1 to §4.5); 16 declare an `Authority`; 25 exist. The answer sets
  what grant inference and raise-set inference cover. Key §10.1 on
  registered providers from the start (see Must Fix's authorization
  entry).

### Legate

- **A script can't take over a body-less redirect.** With
  `redirects: 0`, a redirect raises `Legate::Transport`; only a
  request with a body gets `Legate::Redirect`, which carries `status`
  and `location`. Since a cross-origin hop drops every header but four
  defaults and those `net.redirect_headers` names, a script whose
  target needs another has no way to re-issue the request itself. Fix: raise
  `Legate::Redirect` whenever the redirect budget is spent at 0. Wait
  for a live case before building it.

- **`Legate::Path#under?` doesn't resolve `..`.** It compares
  components lexically, so `Legate::Path.new("/work/../etc")` is
  `under?` `/work`, and `split_path` splits on `/` only, so a Windows
  path is one component. The broker doesn't use it, since grants
  resolve with `realpath`, so this is no escape; but a script using
  it as a boundary check, as LEGATE.md §5.1 invites, gets a wrong
  answer. The fix is normalising `.` and `..` before comparing, and
  refusing (or documenting) a relative path that climbs above its
  start.

- **Audit records lack §8.7's bytes, duration and argument detail.**
  LEGATE.md §8.7 asks for bytes moved, duration, and arguments with
  bodies hashed; its status table already says "narrower than
  specified". An `AuditRecord` has timestamp, verb, subject,
  authority, decision and exception class. The broker writes it before
  the effect runs, so bytes and duration aren't known yet; meeting §8.7
  needs the record completed after the verb finishes, or a second
  record. Unchecked: whether a stream's re-iteration writes a distinct
  record, and whether a fatal exception is recorded before unwinding,
  both of which §8.7 also requires.

- **`Legate::Stream` implements 9 of the ~35 operations §6
  specifies.** Found 2026-09-21 in the census for the agent skill.
  `stream.cr` defines `map`, `select`, `reject`, `take`, `first`,
  `each`, `count`, `sum` and `to_a`; the rest of §6.2–§6.4 (`each_slice`,
  `with_index`, `find`, `min`/`max`, `reduce`, `top_by`, `tally`,
  `sort_by`, `group_by`, …) do not exist, yet LEGATE.md §0 marks §6
  "Built". §0 now says "Partial" and lists the nine. Build the rest by
  what the skill exam shows models actually reach for.

- **`Stream#to_a`'s `TooLarge` hint names methods that don't exist.**
  Found alongside the above. The message recommends `each_slice`,
  `top_by` or `tally`, none of which a stream has, so a model that
  follows the diagnostic gets a second error. LEGATE.md §9's
  `TooLarge`/`TooMany` rows have the same problem. Until those
  operations exist, the hint should name what does: `each`, `take` or
  `first(n)`.

- **The pinned socket's TLS path is only exercised when a transcript
  is RECORDED.** Found 2026-08-30. The plain socket half is covered
  offline: `http_client_pinning_canary_spec.cr`
  stands up a loopback HTTP server and pins to it from a client whose
  hostname (`canary.invalid`) cannot resolve, so a response can only
  arrive if the pinned address was used and the name never consulted.
  What that spec does NOT cover is the `OpenSSL::SSL::Socket::Client`
  branch — SNI and certificate verification against the logical
  hostname while connected to the pinned address — because that needs
  a local TLS server with a certificate the client will accept. Will
  Fix. The practical verification meanwhile is re-recording: deleting
  a transcript under `spec/transcripts/` and re-running with
  `WIRETAP_RECORD=1` forces a real TLS handshake through the pinning
  override. Fix shape: a
  self-signed certificate generated per-run plus a client context
  trusting it, which is a chunk of setup worth doing deliberately
  rather than inline in a spec.

- **`Legate.fetch`'s `body:` does not stream an Enumerable.** Found
  2026-08-30. §4.5 says `body:` accepts a String or an Enumerable "so
  uploads stream"; an Array is currently joined into a single String
  before the request is built, so the memory saving the sentence
  promises does not happen. Will Fix. The response half of streaming
  has since landed (`Utils::HttpResponseStream` plus `stream: true`),
  and this is the remaining half: it needs the REQUEST body written
  incrementally to the connection rather than materialised first,
  which `HTTP::Request` accepts as an `IO` but Legate does not yet
  supply. Note the interaction already settled in §4.5 — a redirect on
  a request that carried a body is handed to the script, so a
  single-pass upload stream never has to be replayed.

- **`Legate.records` cannot consume a stream.** Found 2026-08-30,
  logged 2026-08-31 after `stream: true` landed.
  `Legate.records(path, format:)` opens the path itself, so a body
  from `Legate.fetch(..., stream: true)` cannot be fed to it — a
  script wanting to pull JSONL rows off a network response has to
  buffer the whole thing first, which defeats the streaming it just
  asked for. Will Fix. The plumbing is closer than it looks: both
  parsers already consume an iterator rather than a file specifically
  (`:jsonl` builds on `Lines::LineIterator`, `:csv` on
  `CSV::Parser`), so what is missing is a second entry point.
  Undecided whether that is `Legate.records(stream, format:)` or
  `response.records(format:)`; the second reads better at a call site
  but puts a parsing concern on `Response`.

- **`Response#json` cannot parse a streamed body.** Found 2026-08-30,
  logged 2026-08-31. `#json` raises `Legate::Malformed` on a
  non-String body, so `stream: true` and `.json` are mutually
  exclusive. Correct as it stands — the alternative is silently
  buffering a body the script explicitly asked not to buffer — but it
  means a large JSON document has no streaming path at all. Will Fix
  eventually, and materially harder than the `records` entry above: it
  needs an incremental JSON parser, not just a different entry point,
  and Crystal's `JSON::PullParser` over a chunk iterator is the
  obvious starting point rather than a settled design.

- **No wall-clock bound on a script or on a held-open stream.** Found
  2026-08-30 designing `stream: true`. `Legate.fetch`'s `timeout:`
  becomes the client's connect and read timeouts, which bound each
  individual READ but not total duration: a server dribbling one byte
  every few seconds keeps a connection open indefinitely without ever
  tripping a read timeout, and a script holding that stream stays
  alive with it. `Limits#wall_clock` exists and is unenforced for the
  same reason. Will Fix, and deliberately NOT solved inside one verb —
  this is the same problem as an infinite loop in a script, and wants
  one watchdog at the `Interpreter#eval` boundary rather than a
  duration check invented separately in `fetch`, `exec`, and every
  future long-running verb. The run-teardown seam added for
  `open_sources` is the natural place to hang it, since it already
  owns "this run is over, release everything."

- **IPv6 literals can't be written in a `net.hosts` rule.** Found
  2026-08-30 building `net_rule.cr`. The scalar parser splits a
  `host:port` entry on the colon, which is unambiguous for a DNS name
  and hopeless for `2001:db8::1`; bracketed forms
  (`[2001:db8::1]:8443`) aren't handled either. The parser *rejects*
  both loudly with an `ArgumentError` at policy-load time rather than
  mis-splitting on the first colon, so nothing silently misbehaves — a
  policy naming an IPv6 literal fails to load instead of quietly
  building a rule for a host that doesn't exist and then denying every
  real connection to it with a baffling reason. Will Fix rather than
  Must Fix: the same grant is expressible by hostname today, and the
  failure mode is loud and immediate. Fix shape: bracket-aware
  splitting in `NetRule.parse`, plus a decision on whether a bare IPv6
  address should be grantable at all, given §8.2's address-range
  checks are about to reject most of the interesting ones anyway.

- **§2.7's `include Legate::Read` submodule-include feature (dropping
  the `Legate.` prefix, e.g. `include Legate::Read; read("x")`) isn't
  implemented at all — no code references it anywhere.** Found
  2026-08-27, systematic audit of the read-verb slice against
  LEGATE.md. Not a bug — nothing currently shipped is broken by this
  — just real, specified surface (§2.7's own worked example) with
  zero implementation, worth tracking explicitly rather than
  rediscovering later. Will Fix rather than Must Fix: every verb is
  already reachable fully-qualified (`Legate.read(...)`, §2.7's own
  "available fully qualified, always, with no setup"), so the
  submodule form is sugar, not something currently blocking a script
  from doing anything. Fix shape not yet scoped — likely needs each
  grant-category submodule (`Legate::Read`, `Legate::Write`, ...) to
  actually exist as an includable module whose methods delegate to
  the same native singleton methods already bootstrapped on `Legate`
  itself, rather than a second copy of each verb's implementation.

- **`Legate.grep`'s documented `Timeout` (LEGATE.md §4.1) doesn't
  actually raise `Legate::Timeout`.** Found 2026-08-27 implementing
  `grep.cr`: unlike every other §4.1 verb, grep's own Raises list
  includes `Timeout` — the only sensible reading is that a scan across
  a large fileset should be able to notice it's taking too long
  MID-scan, not just at the single up-front broker call every other
  verb makes once. What `grep.cr` actually does is call
  `Budget#check_wall_clock!` once per file in its scan loop (real,
  working protection against a runaway multi-file scan) — but that
  raises the FATAL, unrescuable `Legate::FatalSignal(:exhausted, ...)`
  (budget.cr), not the script-catchable `Legate::Timeout` RuntimeError
  class (exceptions.cr) LEGATE.md's own text names. No kwarg or
  default duration for a SEPARATE, grep-local, recoverable timeout is
  documented anywhere — inventing a second, independent timer with
  its own semantics felt like more new, unspecified design surface
  than one verb's implementation should decide unilaterally. Needs a
  real decision: either LEGATE.md's text is describing the existing
  fatal wall-clock mechanism loosely (in which case the doc should
  stop implying a script can `rescue` it), or grep genuinely needs its
  own recoverable per-call deadline (in which case its kwarg/default
  need designing first).

- **No terse, agent-facing reference doc for Legate (and Adjutant's
  Ruby subset generally) exists yet.** `LEGATE.md`/`ERRORS.md`/
  `SCOPE.md` are correctness/completeness documents for a human
  implementer, not what a small model (target: 16K+ context) should
  read to learn what to write — different audience, different job,
  and padding a small model's context with design rationale it can't
  act on costs it real task room. Deliberately deferred, not
  overlooked: nothing about the verb surface is stable yet, so
  anything written now would describe intent rather than real
  signatures/errors/edge cases, and the actual hard-to-infer-from-
  Ruby-subset-syntax spots won't be known until scripts are written
  against a real implementation. Revisit once `Legate` verbs exist and
  are being dogfooded — likely worth generating this doc from
  `LEGATE.md` (e.g. via a machine-extractable annotation convention on
  verb signatures) rather than hand-authoring a parallel prose doc, so
  the two can't silently drift apart.

- **`Legate::Exit` — DECIDED 2026-09-10: removed entirely.** Found
  2026-09-05, while removing `Legate.run`'s scaffolding (§4 step 1),
  as an open question between two options: retire the whole type
  alongside `run` (no producer, and won't be while exec stays out of
  scope), or leave it as a plain, producer-less record shape against
  the chance a future non-process source wants the same
  `code`/`out`/`err`/`duration` shape. Settled on the former — if
  something ever needs that shape again, it can be rebuilt with full
  context for whatever it's actually serving, rather than kept alive
  now on the chance it might be useful later. `raise!` had already
  been removed (its only exception class, `Legate::NonZeroExit`, was
  scaffolding for `run`); the rest
  (`code`/`ok?`/`out`/`err`/`truncated?`/`duration`) is now gone too
  — `legate/exit.cr` deleted, its bootstrap call and `require`
  removed from `interpreter.cr`/`legate.cr`, LEGATE.md's §5.6, its
  §3 type-index row and diagram node, and its §11 counts (value
  types 6→5, methods ~47→~41) all updated to match. The Exit-specific
  IFC-labeling test in `risk_flow_propagation_spec.cr` was removed
  rather than adapted — Entry/Match/Response already exercise the
  identical selective-labeling pattern, so no real coverage was lost,
  just a redundant fourth instance of it.

- **`Legate.log` is `Legate.log(message, fields = {})`, not the
  spec'd `Legate.log(message, **fields)`.** Built 2026-09-08 (§4 step
  2). Adjutant's native-call dispatch has no wildcard-kwarg mechanism
  — every native method declares a FIXED `kwarg_names : Set(String)`
  (`NativeCallable#kwarg_names`), and `VM#check_unknown_native_
  keywords!` rejects any name outside it; an empty declared set (the
  default, and every native method until now) rejects every kwarg
  name outright. There is no "accept anything" escape hatch. Building
  real support for that — a sentinel `kwarg_names` value, or a
  parallel dispatch path — would be a genuine VM-level change, and
  doing it for the sake of one convenience verb's exact spelling felt
  disproportionate; the positional-Hash form carries identical
  information (`Legate.log("done", {status: "ok"})` vs the spec'd
  `Legate.log("done", status: "ok")` — same data, different
  punctuation). Worth doing properly — generalized native kwarg
  support — if a second verb ever wants the same thing; not before.
  `legate/verbs/log.cr`'s own top comment has the full reasoning.

  **Addendum, confirmed against a live `crystal build` the same day:**
  the positional-Hash form turned out not to be merely a dispatch
  workaround — it's load-bearing for a SECOND, independent reason.
  `Log::Metadata`'s own top-level entries are `Symbol`-keyed
  (`Log::Metadata#setup`, Crystal stdlib), and Crystal symbols cannot
  be created dynamically at runtime AT ALL — only from a literal
  known at compile time. `fields`' keys are chosen by the SCRIPT at
  runtime, so they could never have been Metadata's own top-level
  entry names regardless of how they arrived (kwarg spray or Hash
  argument) — a real `**fields` implementation would have hit this
  exact wall too. The fix (`legate/verbs/log.cr`): nest the whole
  `fields` Hash one level down, under the single Symbol key `:fields`
  — a literal in that file, known at compile time — since `Log::
  Metadata::Value::Type` explicitly allows a String-keyed Hash as a
  NESTED value, just not as Metadata's own top-level keys. Worth
  knowing for whoever eventually builds generalized native kwarg
  support per the paragraph above: it would face the identical
  Symbol-key wall at the Log layer, unrelated to and not solved by
  fixing VM dispatch.

- **`Legate.scratch`'s directory is emptied at the end of every
  `Interpreter#eval` call, not at the end of an agent's whole
  session.** Built 2026-09-08. §4.7 says scratch "is emptied when the
  script exits," and this codebase's own existing vocabulary already
  settles what "the script" means for exactly this kind of resource:
  `OpenSources`'s own comment ("SCOPE IS THE RUN, NOT THE PROCESS")
  defines it as one `eval` call, specifically because an Interpreter
  is long-lived and may run many. Applied the same rule to scratch
  for consistency, but it is a real product decision with a real
  cost: an agent doing multi-step work across several `eval` calls on
  one Interpreter (exactly DEVELOPMENT.md's own description of the
  intended use) gets a FRESH scratch directory every call, so
  anything written to scratch in one step is gone by the next. If
  that turns out to matter in practice, the fix is either a
  session-scoped scratch dir with its own (currently nonexistent)
  session-end teardown hook, or leaning on a real `write:` root for
  anything meant to survive across steps and reserving `scratch` for
  genuinely single-call incidental space. `legate/broker.cr`'s
  `@scratch_dir` comment has the full reasoning; not revisited here.

- **`Legate.now` reuses the core `Time` class rather than a
  `Legate::Time`, and its RubyClass is looked up at CALL time, not
  bootstrap time.** Built 2026-09-08. Worth recording as a pattern,
  not just a fact about this one verb: `Interpreter#bootstrap_
  builtin_classes` registers `Time` (and any other core builtin
  reached via `register_builtin_class` outside `bootstrap_legate`
  itself) AFTER `bootstrap_legate` runs, not before — so any FUTURE
  Legate verb that needs to construct a value of some OTHER
  core-builtin type will hit the identical ordering hazard, and the
  identical fix (`interp.get_global(name)` inside the native block,
  deferred to call time) applies. Didn't reorder `bootstrap_builtin_
  classes` itself to register `Time` earlier — it's a shared sequence
  this file doesn't own, and the call-time lookup sidesteps the
  problem entirely for a fraction of the risk. Also: `Legate.now`'s
  "frozen" is aspirational, same as `Legate::Response`'s own
  documented "frozen" claim (`legate/response.cr`) — Adjutant has no
  real `freeze`/`frozen?` mechanism at all (`vm.cr`'s `dup`/`clone`
  comment says the same); a script can still mutate the returned
  value via `#utc`/`#gmtime`/`#localtime`. Not specific to this verb,
  just newly relevant to it.

- **`Legate::Broker`'s default `log:` printed to STDOUT for every
  `Legate.log` call, in direct contradiction of what shipped
  documenting it.** Found 2026-09-10, via a real `ops test` run —
  not a code review, an actual observed symptom (`ambient_basics.rb`/
  `ambient_edge_cases.rb`'s own `Legate.log` calls printing during
  the test run). The broker's default was `::Log.for("adjutant.
  legate")`, and every comment/spec-text describing it (`broker.cr`,
  LEGATE.md §4.7) confidently asserted this was a silent no-op,
  "matching Crystal's own 'unconfigured sources emit nothing'
  default." That default doesn't exist — checked properly this time:
  Crystal's stdlib docs state plainly, and have since at least
  0.35.1, that "by default entries from all sources with Info and
  above severity will be logged to STDOUT using the Log::IOBackend."
  `::Log.for(name)` binds to `Log.builder`, the process's ONE shared
  global builder, so ANY unrelated code anywhere in the same process
  calling (or not calling) `Log.setup` affects every Adjutant
  embedding's `Legate.log` output too — the opposite of the isolation
  the whole design was supposed to provide. Fixed by binding the
  default to `Legate::Broker::DEFAULT_LOG`, a private `Log::Builder`
  with no bindings at all, genuinely independent of the rest of the
  process. Regression spec added (`broker_spec.cr`, `"#log
  default"`) checking the builder identity directly, since capturing
  real STDOUT output reliably in a spec is its own source of
  flakiness this fix doesn't need to take on.

  **Addendum, same day: the first fix was itself incomplete.** The
  new regression spec caught it immediately — `Interpreter.new` with
  no `log:` failed to match `DEFAULT_LOG`. `Legate::Broker#initialize`
  was fixed, but `Interpreter#initialize` and `spec_helper.cr`'s
  `make_interp` each carried their OWN independent copy of the same
  `log : ::Log = ::Log.for("adjutant.legate")` default expression,
  written separately when `log:` was first threaded through each
  layer (step 2, `scratch`/`log`/`fail`). Since both always pass
  `log:` through EXPLICITLY to the layer below, their own stale
  default silently overrode the fix for any caller that doesn't pass
  `log:` itself — which includes `test_runner.cr`, meaning the actual
  script-test suites (`ambient_basics.rb`/`ambient_edge_cases.rb`)
  were probably STILL printing to STDOUT even after the first "fix"
  shipped. Both now reference `Legate::Broker::DEFAULT_LOG` directly
  rather than re-deriving their own copy — the actual lesson here
  isn't "remember every call site," it's that a default value worth
  getting right belongs in exactly ONE place, referenced everywhere
  else, precisely so a fix like this one can't fail to propagate.

  Worth being blunt about: this is the same failure mode as the
  `retry` entry above (a confident, specific, wrong claim about
  runtime behavior, shipped and repeated across multiple files) and
  the `SCOPE.md` citation error in that same entry — except this one
  was caught by the person running the tests, not by re-reading the
  code. All three came from the same root cause: asserting how a
  Crystal stdlib API behaves from confident recollection rather than
  checking, in a codebase whose own stated practice — see this file's
  own repeated "not independently verified against a live toolchain"
  flags elsewhere — exists specifically to catch this. The `Log`
  module in particular has now produced three separate mistakes this
  session (the `Hash` vs `NamedTuple`/Symbol-key question in
  `log.cr`'s `emit` call, this default, and almost a fourth just now
  in scoping this very regression spec) — worth treating any future
  claim about `Log`'s behavior as unverified until checked against
  the actual docs or a real run, not just this one.

### Tooling

- **`Compiler::OVERLOADABLE_OPERATOR_NAMES` names the opposite of
  what it holds.** It lists the operator method names a script may
  not define (U017), because each compiles to a fixed opcode. For the
  code-cleanup phase: rename it (`FIXED_OPCODE_OPERATORS`, say).

- **Legate keeps aliases for types that moved to core.**
  `legate/open_sources.cr`, `legate/audit_log.cr` and
  `legate/budget.cr` exist only to alias `Closable`, `OpenSources`,
  `AuditRecord`, `AuditLog` and `Budget` under `Legate::` names, and
  28 references in `src/` and `spec/` still use them. For the
  code-cleanup phase: rename the references to the core names and
  delete the three files.

- **Eleven ameba rule classes were excluded per-file rather than
  fixed.** Added 2026-09-01, when the `Effect` rename forced an ameba
  bump from 1.6.4 to 1.7.0 and the new version reported warnings
  across a large part of `src/`. Deferred until after the `add-legate`
  merge so the warnings would not have to be fixed twice, over two
  partly-overlapping sets of files.

  **Cleared 2026-09-02.** `.ameba.yml` now carries no exclusions at
  all. Of the eighteen warnings that survived `--fix`: eight
  `Lint/ElseNil` and six stale `Lint/UnneededDisableDirective` were
  mechanical; `Lint/UselessAssign` and `Lint/VoidOutsideLib` were one
  each; and three `Metrics/CyclomaticComplexity` were real. Two of
  those three were split into genuinely separate methods
  (`NetRule.parse` into its two accepted spellings,
  `RiskWalker#walk_super_target` into its singleton and instance
  branches) rather than silenced. The third, `bootstrap_regexp`, took
  an inline `ameba:disable` with a stated reason, matching the
  convention `range.cr` and `helpers.cr` already use: its branch count
  comes from how many methods `Regexp` has, not from tangled logic.

  Keep the file empty. A per-file exclusion turns a rule off for code
  nobody has looked at yet, including code written later — which is
  how the 1.7.0 warnings reached eighteen files in the first place.

## Deliberate non-goals

Permanent exclusions are in [UNSUPPORTED.md](./UNSUPPORTED.md), a
reference rather than a work queue. To decide where something belongs:
an item here is expected to leave by being fixed; an entry there leaves
only if the reasoning that excluded it stops holding, which is a design
conversation of its own.
