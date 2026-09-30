# Handoff

Working notes between development sessions, kept current by whoever ends a session. Not user documentation.

Last updated at the end of the `fix-ruby-divergences` branch, before its merge to `main`.

## How to use this document

Sections marked **[Retain]** carry forward unchanged unless a convention in them changes; when one does, edit it in place. The other sections describe the current state and are rewritten at the end of each session, in the same commit as the session's last work. The commit log is the history, so this file keeps none.

On arrival, check this document against the repo before proposing work: branch names, commit claims and "done" statements can be wrong.

---

## 1. The project [Retain]

Adjutant is a subset of Ruby implemented in Crystal (parser → compiler → bytecode VM). It is meant for models to write, and an agent harness assesses a script's risk before running it in secure environments. **Legate** is its capability-based standard library: the only way a script touches files, the network or the environment, and only as far as its policy grants.

`skills/adjutant/SKILL.md` teaches a model to write Adjutant. The exam in `spec/skill/` measures whether it works; `spec/skill/README.md` records every sitting and is the evidence behind every line of the skill.

Key documents: `SCOPE.md` (known defects and gaps: Must Fix, Will Fix), `LEGATE.md` (Legate's spec, with a status table), `UNSUPPORTED.md` (U-codes, deliberate exclusions), `ERRORS.md` (diagnostic catalog), `DEVELOPMENT.md` (how the code works, for contributors), `spec/skill/TODO.md` (exam backlog, and the comment-cleanup scripts).

## 2. Working conventions [Retain]

1. **Division of work.** Claude clones the repo and presents edited files for review; the human saves, tests, commits and pushes. Fewer than ten modified files, present the files, keeping their repo directories when two share a name; ten or more, one patch per commit, checked with `git apply --check` against the branch head. A follow-up to a patch already applied is its own incremental patch. Claude sets up no toolchain. Claude proposes a one-line commit message when a change is ready.
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
12. **Lint as CI runs it.** Ameba accepts only `e` or `ex` for a rescued exception, rejects one-letter block parameters, `not_nil!`, `return nil` and `| Nil`, prefers `max_of?` to `map { }.max?`, and caps cyclomatic complexity at 12; split a method rather than disable the check. A new method goes above a method's doc comment, never between it and its `# ameba:disable` line. Crystal has no chained comparisons (`0 < x <= 9`), no trailing `while`, no variable defined in a modifier's condition, and reserves `responds_to?`, `is_a?`, `nil?`, `as` and `as?`.

## 3. The evidence method [Retain]

1. **Adjutant is a proper subset of Ruby.** Anything it accepts and then runs differently from Ruby is a Must Fix defect, however rare. Adding a method or form Ruby lacks also breaks the subset. A construct Ruby accepts and Adjutant rejects is either a deliberate exclusion, with a U-code in `UNSUPPORTED.md`, or a gap that raises and is logged in Will Fix; never a silent difference. Dynamic classes, modules and meta-programming are the usual candidates for exclusion, and are discussed before deciding.
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
5. **A check made once for a group must hold for every member.** `grep` and `list` consult the policy for a glob's fixed prefix and label every match with it; a recursive `cp` authorizes the tree's root and copies whatever the walk reaches. Per-member facts (sensitivity, containment, symlinks) need per-member checks.
6. **A walk handed to a library inherits the library's symlink policy.** Crystal's `cp_r` follows symlinks; its `rm_r` doesn't. Read the library before trusting either.
7. **A verifier that can't fail proves nothing.** The comment checker passed on a nonexistent path, because empty equals empty; it now checks existence. Give every check a case it must reject. Likewise a spec file not named `*_spec.cr`: `crystal spec` never runs it, and the suite stays green.
8. **Everything a nested run sets aside must still count.** A block a native method runs, a method it calls, and a file `require` loads each run with the caller's frames set aside. Call depth, instructions and the run boundary (budgets, streams, scratch) all leaked through that gap until each was counted across it.
9. **Script data can be nested as deep as memory allows.** A recursive walk over it in Crystal ends the host process. Walks over script containers go through `ContainerWalk`, or re-enter the VM and so meet `call_depth_limit` (DEVELOPMENT.md).
10. **"Per run" means per `eval`.** State built once per Interpreter (the Broker's Budget) outlives runs unless something resets it; `Budget#start_run!` does, from `Interpreter#eval` only.
11. **Two equalities, two methods.** `Value#==` is Ruby's `eql?`, which Hash keys and container `eql?` use (`5` and `5.0` differ); `ValueOps.equal?`, reached through `VM#values_equal?`, is Ruby's `==`. Code comparing Values must pick the one Ruby would.
12. **A leak hides wrong tests.** While block-assigned names leaked as globals, several specs passed by reading a name a neighbouring test had set. Fixing a leak, expect tests that were wrong all along; fix them to Ruby's behaviour rather than restoring the leak.
13. **Every place Ruby's grammar says `arg` stops before `and`/`or`.** Assignment's right-hand side, call arguments, ternary branches and `not`'s operand all use `PREC_AND_OR`; a new construct taking an argument should too.

---

## 5. State

The `fix-ruby-divergences` branch cleared Must Fix of Ruby divergences: all 27 it began with, and each one its fixes turned up. In outcome:

1. **Calls:** positional arity is checked as Ruby checks it, for script methods, lambdas and every builtin; parameters bind in Ruby's order; parameter lists Ruby rejects don't parse; receiver calls take arguments without parentheses; `and`/`or` stay out of call arguments.
2. **Scope and syntax:** a block's new names are local to it, and a `for` loop's outlive it; operator precedence is Ruby's table; `rescue` takes class expressions; Integer prefixes, octal, quoted and operator Symbols, and several heredocs per line all read as in Ruby; stray `break`/`next` and callback hooks are rejected.
3. **Values:** Hash keys compare with `eql?`; indexing covers Ranges, start and length, padding and splicing; Strings are frozen, as under `# frozen_string_literal: true`.
4. **Objects:** NoMethodError where Ruby raises it; `is_a?` through nested includes; identity `equal?`; `respond_to?` for universal methods and operators; copies that keep native state; Exception subclasses' `initialize`; Comparable as a module, the only source of derived `==` and ordering.
5. **Builtins:** Ruby's `split`, `join`, `each_line("")`, `Hash#each` pairs, `reduce(:sym)`, Float `%`, Regexp edges; blockless iterators raise U022 (no Enumerator).

Must Fix now holds only the two policy-design entries. Will Fix was checked against the code and holds 55 entries, still in the older dated style. `SKILL.md` was updated for slicing, `inject(:sym)`, Comparable and U022.

Model           |Latest result|Notes                          
----------------|-------------|-------------------------------
qwen3.8 (27B)   |10/10        |At the exam's ceiling          
Muse Glimmer 30b|10/10        |At the exam's ceiling          
Ornith 1.5 (9B) |6/10         |03, 04, 08, 10 are model errors

These sittings predate this branch, which changed what a model's code does (block scoping, precedence, error classes, arity) and edited the skill. A sitting is needed before trusting the table.

## 6. Next

1. **Merge `fix-ruby-divergences`** to `main`.
2. **Sit the exam** on all three models, to confirm the skill after this branch.
3. **Exam tasks 11 to 13** (`spec/skill/TODO.md` §1). Task 12 was meant to hit Array-keyed Hashes and slice assignment, both now fixed, so it becomes a regression check rather than evidence.
4. **Will Fix, style pass**, by subsection, on its own branch: drop dates and history and bring the prose to the Must Fix style.
5. **The two policy-design entries** before 1.0, since the configuration document changes an embedder-facing format.
6. **§10, the static analyser.** It begins with a design question, what counts as the "effectful surface"; see Will Fix, Static risk assessment.

## 7. Open decisions

- **D5. `Time.now`.** Core's ungated `Time.now` sits beside `Legate.now`, and `SKILL.md` both maps one to the other and whitelists `Time.now`. Keep it, fixing the skill, or bring it under U021?
- **`Legate::Path#under?`.** It doesn't resolve `..`, so it misleads a script using it as a boundary check. Logged under Will Fix, Legate; promote to Must Fix?
- **`Legate::Response` headers.** LEGATE.md §5.5 calls them frozen; Adjutant freezes only Strings. Correct §5.5, or add freezing to the backlog?
- **LEGATE.md §1** says the core is "ordinary Ruby with mutation removed". It isn't: `<<` and `[]=` mutate Arrays and Hashes. Correct it at the next spec revision.
- **`inspect` of deep data.** Printing an Array or Hash nested deeper than `call_depth_limit` (256) raises L002, since each level re-enters the VM. JSON from `fetch` may nest to 512. Make `inspect` walk built-in containers iteratively (safe, since scripts can't override their `inspect`, U003), or leave it?
- **Default budgets.** `wall_clock` 300 s, `total_read` 4 GiB, `total_write` 1 GiB and `memory` 512 MiB (advice only) are LEGATE.md §7's example values. Revisit once a harness runs real workloads.
- **`rescue => e` inside a block.** `emit_store_name`'s `force_define` binds `e` as a block-local even when an enclosing `e` exists, on the claim that Ruby does the same. Unverified; if Ruby assigns the enclosing variable instead, it's a Must Fix divergence.

## 8. Deferred tests

`authorization_spec.cr`'s symlinked-root test (Windows CI cannot create symlinks) and `verbs/fetch_stream_spec.cr`'s raise-mid-walk test (believed a Crystal runtime defect; investigation closed).
