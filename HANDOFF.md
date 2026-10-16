# Handoff

Working notes between development sessions, kept current by whoever ends a session. Not user documentation.

Last updated on `parser-gaps`, before its PR.

## How to use this document

Sections marked **[Retain]** carry forward unchanged unless a convention in them changes; when one does, edit it in place. The other sections describe the current state and are rewritten at the end of each session, in the same commit as the session's last work. The commit log is the history, so this file keeps none.

On arrival, check this document against the repo before proposing work: branch names, commit claims and "done" statements can be wrong.

---

## 1. The project [Retain]

Adjutant is a subset of Ruby implemented in Crystal (parser → compiler → bytecode VM). It is meant for models to write, and an agent harness assesses a script's risk before running it in secure environments. **Legate** is its capability-based standard library: the only way a script touches files, the network or the environment, and only as far as its policy grants.

`skills/adjutant/SKILL.md` teaches a model to write Adjutant. The exam in `spec/skill/` measures whether it works; `spec/skill/README.md` records every sitting and is the evidence behind every line of the skill.

Key documents: `SCOPE.md` (known defects and gaps: Must Fix, Will Fix), `LEGATE.md` (Legate's spec, with a status table), `UNSUPPORTED.md` (U-codes, deliberate exclusions), `ERRORS.md` (diagnostic catalog), `DEVELOPMENT.md` (how the code works, for contributors), `spec/skill/TODO.md` (exam backlog, and the comment-cleanup scripts).

## 2. Working conventions [Retain]

1. **Division of work.** Claude clones the repo and presents edited files for review; the human saves, tests, commits and pushes. Fewer than ten modified files, present the files, keeping their repo directories when two share a name; ten or more, one patch per commit, checked with `git apply --check` against the branch head. A follow-up to a patch already applied is its own incremental patch. Claude sets up no toolchain unless the human asks, as for the ruby/spec import, where Crystal and Ruby in Claude's sandbox check each translated file on both. Claude proposes a one-line commit message when a change is ready, and a PR description when a branch is: two sections, "What?" and "Why?", giving outcomes and motivations and leaving out what the commits and code already show.
2. **Pull before delivering.** Pull at the start of a turn and again just before building the files or patches, since the human may push in between.
3. **Branches.** Runtime fixes go on a sub-branch or directly on the working branch, at the human's call. Either way, a commit never mixes Crystal changes with exam or skill changes.
4. **`SCOPE.md` entries are removed when resolved**, not marked resolved. History belongs in the commit log; rationale goes in `DEVELOPMENT.md` only when a future contributor needs it.
5. **Comments and docs describe the current state.** Code comments document how to use an API and what a type or function produces; inside a function, the steps it takes. No dates, no change history, no "previously". Keep a short "why" only where it stops someone undoing a deliberate choice.
6. **Comment-only changes are verified mechanically**: every non-comment line, and every `# ameba:` directive, identical to HEAD (`code_unchanged.sh`, in `spec/skill/TODO.md` §4).
7. **State a convention's reasons accurately.** Don't dress a convention up as a guarantee the project never made, or a future contributor will defend a property nobody promised.
8. **Test-harness errors do not belong in the error catalog.** Mistakes in a spec raise plain `RuntimeError`s, not R-codes.
9. **Never `git reset --hard` with uncommitted work in the tree.**
10. **Markdown tables:** no literal `|` inside a cell; reword instead.
11. **Spec first, when it can run.** A spec that compiles against the old code and fails there is its own commit, ahead of the fix. One that needs the fix's API, or would crash, hang or overflow the stack on the old code, goes in the same commit.
12. **Lint as CI runs it.** Ameba accepts only `e` or `ex` for a rescued exception, rejects one-letter block parameters, `not_nil!`, `return nil` and `| Nil`, prefers `max_of?` to `map { }.max?`, and caps cyclomatic complexity at 12; split a method rather than disable the check. A new method goes above a method's doc comment, never between it and its `# ameba:disable` line. Crystal has no chained comparisons (`0 < x <= 9`), no trailing `while`, no `rescue` type list continued onto a new line after `|`, no variable defined in a modifier's condition, and reserves `responds_to?`, `is_a?`, `nil?`, `as`, `as?` and `out` (a C-binding keyword, so `return out unless …` won't parse). Inside an `enum`, a member's name shadows a type of the same name: write `::Regex` in `PatternType`.
13. **Spec helpers are per file.** `with_tmpdir`, `net_grants` and their kind are private to each spec file, so a new file defines its own. `allow_unlisted` is a private method of `module Adjutant` in `spec_helper.cr`, so a helper calling it is a `private def self.` inside that module.

## 3. The evidence method [Retain]

1. **Adjutant is a proper subset of Ruby.** Anything it accepts and then runs differently from Ruby is a Must Fix defect, however rare. Adding a method or form Ruby lacks also breaks the subset. A construct Ruby accepts and Adjutant rejects is either a deliberate exclusion, with a U-code in `UNSUPPORTED.md`, or a gap that raises and is logged in Will Fix; never a silent difference. Dynamic classes, modules and meta-programming are the usual candidates for exclusion, and are discussed before deciding. UNSUPPORTED.md's standing principles give the test: a construct is excluded only if supporting it adds to what a model must reason about, or it is both rare and significant work; rarity alone only sets a gap's priority.
2. **The model writes the answer; we write the checks.** A model marking its own work agrees with its own misconceptions.
3. **Classify every exam failure as one of three causes:** the skill was wrong, the skill was silent, or the model ignored it. Only the first two justify editing the skill. Failures that turn out to be Adjutant defects go to the runtime instead.
4. **Predict, park, confirm.** A defect found by reading the code goes into `SCOPE.md` unfixed. It is fixed when a spec or a model hits it; for a Must Fix, write that spec first.
5. **A silently wrong answer is worse than an error.** When choosing between "make it work" and "make it raise", either beats "return something plausible".
6. **Take claims from the source, not the docs, and not the comments.** Docs and comments drift; the drift spec guards `SKILL.md`, nothing guards the rest. For Crystal's own behaviour, read Crystal's source.
7. **The 9B model is a canary, not a target.** Its failures are worth reading for runtime defects, which it finds because it writes idioms larger models avoid. Its own mistakes do not justify skill edits. If that ever changes, sit it three times per task first, because single sittings flip.
8. **Check parse failures against Ruby on the assembled file** (`spec/skill/runs/<model>/<task>/<task>.rb`), never the raw answer. A fenced reply turns into Ruby backtick strings, so `ruby -c` passes it unread.

## 4. Engineering lessons [Retain]

1. **A keyword with a case in only one dispatch table is a bug in waiting.** `super` and `yield` were each handled in `parse_statement` alone.
2. **A check copied into two places breaks in both.** `parse_return` and `parse_break` each carried the same value test; they now share `jump_value_follows?`. When fixing a check, look for its copies.
3. **When a native method invokes a block, everything the block needs travels with it.** A block run by a native method executes in a swapped, single-frame `@frames`; nothing can be recovered by walking the stack there.
4. **Blocks and lambdas bind arguments differently.** Blocks spread a lone Array across several parameters (`spread_block_args`); lambdas never do. Lambdas are reached only through `invoke_proc`, which is what keeps the two apart. A `lambda { }` wraps a proc named `<block>`, so the name can't tell them apart.
5. **A check made once for a group must hold for every member.** `grep` and `list` consult the policy for a glob's fixed prefix and label every match with it; a recursive `cp` once authorized the tree's root and copied whatever the walk reached. Per-member facts (sensitivity, containment, symlinks) need per-member checks.
6. **A walk handed to a library inherits the library's symlink policy.** Crystal's `cp_r` follows symlinks; its `rm_r` doesn't. Read the library before trusting either.
7. **A verifier that can't fail proves nothing.** The comment checker passed on a nonexistent path, because empty equals empty; it now checks existence. Give every check a case it must reject. Likewise a spec file not named `*_spec.cr`: `crystal spec` never runs it, and the suite stays green.
8. **Everything a nested run sets aside must still count.** A block a native method runs, a method it calls, and a file `require` loads each run with the caller's frames set aside. Call depth, instructions and the run boundary (budgets, streams, scratch) all leaked through that gap until each was counted across it.
9. **Script data can be nested as deep as memory allows.** A recursive walk over it in Crystal ends the host process. Walks over script containers go through `ContainerWalk`, or re-enter the VM and so meet `call_depth_limit` (DEVELOPMENT.md).
10. **"Per run" means per `eval`.** State built once per Interpreter (the Broker's Budget) outlives runs unless something resets it; `Budget#start_run!` does, from `Interpreter#eval` only.
11. **Two equalities, two methods.** `Value#==` is Ruby's `eql?`, which Hash keys and container `eql?` use (`5` and `5.0` differ); `ValueOps.equal?`, reached through `VM#values_equal?`, is Ruby's `==`. Code comparing Values must pick the one Ruby would.
12. **A leak hides wrong tests.** While block-assigned names leaked as globals, several specs passed by reading a name a neighbouring test had set. Fixing a leak, expect tests that were wrong all along; fix them to Ruby's behaviour rather than restoring the leak.
13. **Every place Ruby's grammar says `arg` stops before `and`/`or`.** Assignment's right-hand side, call arguments, ternary branches and `not`'s operand all use `PREC_AND_OR`; a new construct taking an argument should too.
14. **A catch-all converts everything, including what must pass through.** `VM#call_native` wraps any non-`RuntimeError` as N001: it turned Legate's OS failures into "the host's fault", and a policy tie (H003) or a malformed policy regex into something a script could rescue. An exception meant to stay out of a script's reach needs its own `rescue` clause there, as `FatalSignal` and `AmbiguousRiskFlowPolicyError` have; better still, refuse a configuration error when it is loaded, where its author is.
15. **Put a check where its inputs exist.** The risk-flow check ran in the VM before the call, where the subject isn't known; moving it into `Broker#authorize` is what let a rule name the destination. Check what actually travels, too: a redirect hop is judged on the headers it is sent, not on every argument the call received.
16. **The perimeter and the policy must judge the same thing.** Grants resolved paths and folded hosts; the policy matched what the script typed, so a respelling the grant allowed could steer the policy. Both now go through one function each (`RealPath`, `HostName`). A new kind of subject needs its normal form in that shared place, applied to subjects, origins and exact patterns alike.
17. **Declare an authority for every `authorize_*` call.** Labelled arguments are checked only at a subject for an authority the verb declares; `cp` declared `Write` alone, so its source escaped the read policy.
18. **One name, two behaviours.** Crystal's `File.realpath` resolves every link on POSIX and only a final one on Windows, which left a way out of a granted root there. A test compiled out on one platform hid it, under a reason nobody had checked. Before gating a test on a platform, confirm the reason; when lifting a gate, expect it to find something.
19. **An unread key is a dropped restriction.** `JSON::Serializable` ignores unknown keys, so an Allow exception with `subject` misspelled loaded cleanly and allowed its secret to every host. Every format a host writes is parsed strictly; give each one a spec with a misspelled key that narrows something.
20. **A bound over alternatives must hold for each.** `RiskChoice` summarized its top-ranked branch whole, so a tied branch's recursive delete vanished, and severity and reversibility were copied from one child, so a sequence reported an irreversible call as reversible. Each field of a summary is its own worst case.
21. **A default named for safety must deliver it.** `reject_all` has no sensitivity patterns, so nothing Legate reads is sensitive and nothing is rejected: in practice it means grants only. A policy document must now say `risk_flow: none` to get it. Before making something a default, check what it does with the inputs it will actually see.
22. **Crystal's `raise` takes the arguments that follow it.** `x || raise needs(...)` inside an argument list swallowed the next named argument. Parenthesize a `raise` anywhere but at the end of a statement.
23. **Crystal merges a union of types sharing a parent into the parent.** An array of `Completed`, `Raised` and `Fatal`, a `rescue ex : A | B`, and a variable that may hold either of two siblings are all typed as their common parent, which a restriction naming the siblings refuses. Take the parent and check at run time (`Finished.new`), dispatch on each type (`Worker#raised`), or give types meant to form a union no common parent (`Supervisor`'s outcomes), which also keeps a `case … in` over them exhaustive.
24. **Read what Crystal's serialisers write and accept.** `Time#to_json` drops fractions of a second; `Enum.from_json` folds case; a malformed `Time` raises `Time::Format::Error` or `ArgumentError`, not a `JSON::Error`; `JSON::Builder` stops at 99 levels of nesting, before the parser's 512. Each needed a converter or a wider `rescue` in the protocol.
25. **An exception from a host callback must not be one a script can rescue.** In `call_native` it becomes N001 (lesson 14), and the script carries on. `Worker::Broken`, a `FatalSignal`, carries a protocol failure past every script `rescue`, cleaning up as it goes, and `Worker` unwraps it after `eval`.
26. **On Windows, never wait inside a Crystal `rescue` or `ensure`** (DEVELOPMENT.md, Exception handling). The crash needs a particular fiber interleaving, so it passes now and then: one green run proves nothing, five under random seeds say more. In a CI log from `crystal spec -v`, each finished example's name appears twice (printed at its start, then again after `\r`), so the crash is in the example after the last pair. Build the spec and run it directly to see the exit code, which `crystal spec` drops.
27. **A check on time must charge only the time its subject spent.** The deadline pauses while the host decides; the held-pipe check counts only time a reader waits on its pipe, so a slow host block can't make an honest worker look taken over. A timer that also bounds an adversary needs a hard stop as well: a process writing every 100 ms resets any idle timer, so the Supervisor also stops at the ceiling plus `PIPE_WAIT`.
28. **Read what a library call does besides its job.** Crystal's `Process#wait` closes the child's pipes in its `ensure`, so the Supervisor calls it only once nothing reads them, and learns that the worker ended from `terminated?` instead. That has its own catch: on Windows a process that exited with code 259 (`STILL_ACTIVE`) looks alive, which is why a kill also starts the pipe wait.
29. **A spec that takes only one path through a construct hides the others.** `if … elsif` crashed whenever a branch before the last ran, because its only spec took the last `elsif`; ruby/spec's if_spec found it at once. Spec each branch, and each way in and out of a construct.
30. **Compile a construct the way Ruby defines it.** `loop` is a method with a block in Ruby; compiled inline here, its body shared the method's scope, its closures shared one binding, and `return` worked only by accident. Once `loop` became a call with a block, all three followed from the block's semantics.
31. **A reason given for excluding one form applies to its siblings.** U019 excludes `proc { }` partly because its `return` must leave the enclosing method; every ordinary block had the same need, and none met it. When a U-code's reason names a missing mechanism, check what else needs that mechanism.
32. **An edit that cuts to the next list item can take a heading with it.** Removing the last Must Fix entry by cutting to the next `- **` also removed `## Will Fix` and its first `###`, across five commits nothing noticed. Cut to the next item or heading, whichever comes first, and diff the headings afterwards.

33. **A decision recorded only in a spec's name is still a decision.** Before framing a choice as new, search the specs for the behaviour it would change: "deliberate", "not an oversight", or `should be_nil` on the same methods. Several specs held an earlier "metadata stays unlabelled" rule nobody had written elsewhere; missing them cost a round of the label work.
34. **A default branch that answers "nothing" makes every omission silent.** RiskWalker's `else` gave any node kind without a case no risk, which hid every call inside an operator, a condition or an interpolation; `exec_builtin` answers 0 for `size` on a receiver without one. List the known-safe cases explicitly and make the default the loud or conservative answer: `walk_node` now reports an unknown node kind as unresolved.
35. **Put a rule where every case passes, with a declared opt-out beside each exception.** Labelling each native's result by hand left about forty unlabelled; `VM#label_from_inputs` labels every builtin's result at its two exits, and a method that labels its own declares `labels_own_result: true` where a reviewer sees it.
36. **Crystal types a block's collection by what the block returns, not by the callee's declared type.** `compact_map` over a method declared `: RiskNode` that returns a `RiskChoice` gave `Array(RiskChoice)`, which then refused a `RiskSequence`. Widen inside the block with `.as(RiskNode)`.
37. **A fix that makes an analysis see more exposes its old imprecisions in new places.** Once RiskWalker walked conditions, a variable assigned on only some paths, which its Env deleted, read as a method call in every `if found`. Fix the imprecision in the same change (`merge_envs_into`, `keep_locals`), or the fix trades hidden risk for false alarms.
38. **Where Ruby's behaviour has corners, follow MRI's C function step for step.** `range_max` checks emptiness before exclusivity and raises two different TypeErrors; the lexer's newline case skips comment lines but not blank ones. Reading the function gave every corner the spec needed in one pass, where guessing gave them one failure at a time.
39. **Mirror a Ruby error only where Adjutant matches the rest of Ruby's behaviour.** Ruby raises "can't iterate from X" for any range start without `succ`, but Adjutant's Strings lack `succ`, so that message would tell a model Ruby can't iterate `"a".."c"`. R024 covers only the Float and nil starts, where Ruby agrees; the String gap stays a NoMethodError, logged in Will Fix.

---

## 5. State

`parser-gaps` carries over twenty commits beyond `main`, still open, to merge as one PR once the splat work below is done or split off. The parser gaps on it were chosen by what models write, not by how many imported tests they unblock: each SKILL.md §1 redirect line records a model reaching for the construct, and supporting it deletes the line.

**`&:name`** passes `Symbol#to_proc` as a call's block, with or without parentheses (`items.map &:upcase`, settled by spacing and `known_local?` as `-` and `[` are). It parses to a block with one splat parameter whose body is a `SymbolProcCall`, compiled to `Op::SymbolCall`, so an Array yielded alone is never spread. A literal block as well raises P009. U001 now covers `&` before anything but a Symbol literal at a call site, a variable holding a Symbol included, since only a literal names the method for the risk walker.

**`**` and `**=`** bind and group as in Ruby (`-2 ** 2` is -4, `2 ** 3 ** 2` is 512) and compile to a call of `Integer#**` or `Float#**`, as `<=>` does. U026 excludes Rational and Complex results, raised as a `RangeError` (`2 ** -1`, `(-8) ** 0.5`); `0 ** -1` raises R060, a ZeroDivisionError. `**` in a parameter list raises P001.

**Leading-dot chains.** A line starting with `.x` or `&.` continues the expression before it, past comment lines, as Ruby 2.7's lexer decides (`Lexer#continues_method_chain?`). A blank line ends a chain, and `..` at a line's start is still a range.

**RiskWalker** walks every expression position: operands, conditions, interpolations, indexes, ranges, `return`/`next`/`break` values, `yield` arguments, `for`'s collection and parameter defaults. A short-circuit's right side, a ternary's branches, an `elsif` or `when` condition and a default are Choices. A node kind without a case is unresolved, not safe. A name assigned in a branch, loop or `begin` stays a local afterwards.

**Risk-flow labels** follow one rule, documented in DEVELOPMENT.md: whatever a builtin computes from labelled values carries their label, measurements, predicates and positions included (`secret.size`, `/x/.match?(secret)`, `arr.size` of a labelled Array). `VM#label_from_inputs` applies it at `call_native` and `exec_builtin`, counting an input container by its own label. Three kinds of method declare `labels_own_result: true` and label their own result: one returning an element as is (`Array#first`, `Hash#delete`, a Range's bounds), one describing a labelled object's source (`Stat#mode`, `Response#status`), and one using an input only on some paths (`String#sub`). Natives that yield or collect from labelled input label those values (`Integer#times`, a Range's iterators, `String#chars`).

**Builtins that answered where Ruby doesn't.** `exec_builtin` answers `to_i` and `to_f` only for nil and has no `size` or `length` fallback, so other receivers raise NoMethodError. `Range#size`, `Symbol#length` and `#size`, and `Integer#size` exist. `Range#min` and `#max` follow MRI on empty and exclusive ranges, with R061 and R062 for the exclusive cases Ruby rejects. R024 is now "can't iterate from {class}" and covers a Float start too.

SKILL.md lost its `&:name`, `**` and leading-dot redirects and lists the new methods, so the exam's results below predate the current skill. U026 is recorded in `skill_spec.cr` as omitted from it.

**`spec/scripts/rubyspec/`**: 165 tests run and 163 are blocked, each under `# --- BLOCKED:`. Nothing on this branch unblocked any. The import's tools still live only in Claude's sandbox (§7).

Must Fix is empty. Will Fix gained a Risk-flow tracking group, holding the branch log: a conditional jump on a labelled value records nothing, though that is the path an implicit leak takes.

Model           |Latest result|Notes                                           
----------------|-------------|------------------------------------------------
qwen3.8 (27B)   |10/10        |Last sat before `fix-ruby-divergences`          
Muse Glimmer 30b|10/10        |Sat at `2bfa808`                                
Ornith 1.5 (9B) |7/10         |Sat at `2bfa808`; 02, 06 and 08 are model errors

All three predate #69, which renamed the classes the skill teaches, and this branch's skill changes. The task policies carry `risk_flow: none`, and the runner loads them as full policies. The next sitting is fresh, not a re-run. No current task produces an H code.

## 6. Next

1. **The splat**, in three steps, each as spec, fix, then its SKILL.md line removed in a commit of its own. Nothing outside a parameter list accepts a splat today; `MultiAssign` holds plain targets only.
   1. A call argument (`f(*args)`), an Array literal (`[*a, *b]`), an assignment value (`a, b = *pair`) and a `when` list share one mechanism: `*x` becomes `x` as an Array by Ruby's rules (an Array as is, nil as `[]`, anything else as `[x]`), runs of plain elements become literal Arrays joined by the existing Array `+`, which joins labels, and a call takes its arguments from the Array through one new opcode.
   2. An assignment target (`first, *rest = items`), by giving `MultiUnpack` a splat position.
   3. The double splat (`f(**opts)`, `{**defaults, k: v}`).
2. **Op-assign through an attribute** (`self.count += 1`), the last parser gap with a SKILL.md redirect.
3. **Cheap gaps**: loops as expressions, whose runtime is done and which need only `parse_primary`'s dispatch (spec the `while` modifier and the `do` ambiguity first; it unblocks about 21 tests); `then` after `if`; bare `next` and `break` before `}`, `end` or `else`; `-> x { }`; `return a, b`; `%r{}`.
4. **Probe two predicted misparses for silence**: `raise (x), y` and `super (a), b`, and `until cond do`. If either runs rather than raising, it is Must Fix.
5. **Merge `parser-gaps`**, then sit the exam fresh on all three models, then the next ruby/spec batch (assignments, `def` and calls, blocks; `send_spec.rb` has the `&:name` tests), the streamed-fetch lead on Windows, and exam tasks 11 to 13.
6. **Later**: the branch log (SCOPE.md, Risk-flow tracking), the Will Fix style pass, LEGATE.md §10's static analyser, generic provider loading.

## 7. Open decisions

- **Element reads from a labelled container.** Summaries of a labelled container carry its label (rule (a)), but `arr.first` and `arr[0]` return the element with only its own label. The container's label can hold labels no current element does, so joining it would over-label; not joining it lets a value read out of a container that once held a secret leave unlabelled. Undecided.
- **`defined?`.** A candidate for exclusion by the test in UNSUPPORTED.md: rarely written, and supporting it means a keyword and a check per kind of operand. SKILL.md already teaches the alternative.
- **U019's reason.** UNSUPPORTED.md excludes `proc { }` chiefly for its non-local `return`, which blocks now have. Its lenient arity is still unbuilt, so the exclusion stands, but its reason needs restating, or the exclusion revisiting.
- **SKILL.md and U025.** A model writing sums or timestamps could meet the 64-bit limit. Teach it in the skill (an exam re-sit), or leave it to the diagnostic?
- **The import's tools.** Commit the converter and triage loop (say under `spec/scripts/rubyspec/tools/`), or keep rebuilding them per session?
- **Pending unwinds inside an ensure body.** The VM keeps one pending re-raise, break and return each, so a `begin … ensure` nested inside an ensure body entered for one of them may resume it early. Predicted from the code, unconfirmed; log it in SCOPE.md?
- **D5. `Time.now`.** Core's ungated `Time.now` sits beside `Legate.now`, and `SKILL.md` both maps one to the other and whitelists `Time.now`. Keep it, fixing the skill, or bring it under U021?
- **`Legate::Path#under?`.** It doesn't resolve `..`, so it misleads a script using it as a boundary check (Will Fix, Legate). Promote to Must Fix and answer by real path too?
- **`Legate::Response` headers.** LEGATE.md §5.5 calls them frozen; Adjutant freezes only Strings. Correct §5.5, or add freezing to the backlog?
- **LEGATE.md §1** says the core is "ordinary Ruby with mutation removed". It isn't: `<<` and `[]=` mutate Arrays and Hashes. Correct it at the next spec revision.
- **`inspect` of deep data.** Printing an Array or Hash nested deeper than `call_depth_limit` (256) raises L002. Make `inspect` walk built-in containers iteratively, or leave it?
- **Default budgets.** POLICY.md §3's defaults, `max_asks` 20 among them, were first chosen as examples. Revisit once a harness runs real workloads.
- **Approval cache.** research/IFC_DESIGN.md's open question; kept in a host across runs, it must record only what the host decided and observed (WORKER_DESIGN.md, What a host can trust).
- **Worker protocol, the rest.** WORKER_DESIGN.md's open decisions: stray writes to `STDOUT` from a host's natives, host round trips for natives needing host state, and structured results.
- **Crystal's Windows `File.realpath`.** It follows only a path's final link. Adjutant no longer relies on it; report it upstream?
- **A suffix mode for risk-flow subjects**, only if policy authors keep writing the same regex.
- **`ExecutionLimits` stays out of the document.** Revisit if hosts want one place to bound a run.

## 8. Deferred tests

Two tests are pending on Windows only: `tree_copy_spec.cr`'s FIFO test, since Windows has no FIFOs, and `verbs/fetch_stream_spec.cr`'s raise-mid-walk test, which SCOPE.md's streamed-fetch entry now has a lead for.
