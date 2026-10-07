# Handoff

Working notes between development sessions, kept current by whoever ends a session. Not user documentation.

Last updated after the `windows-realpath` merge (#78), on `main`.

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
12. **Lint as CI runs it.** Ameba accepts only `e` or `ex` for a rescued exception, rejects one-letter block parameters, `not_nil!`, `return nil` and `| Nil`, prefers `max_of?` to `map { }.max?`, and caps cyclomatic complexity at 12; split a method rather than disable the check. A new method goes above a method's doc comment, never between it and its `# ameba:disable` line. Crystal has no chained comparisons (`0 < x <= 9`), no trailing `while`, no variable defined in a modifier's condition, and reserves `responds_to?`, `is_a?`, `nil?`, `as`, `as?` and `out` (a C-binding keyword, so `return out unless …` won't parse). Inside an `enum`, a member's name shadows a type of the same name: write `::Regex` in `PatternType`.
13. **Spec helpers are per file.** `with_tmpdir`, `net_grants` and their kind are private to each spec file, so a new file defines its own. `allow_unlisted` is a private method of `module Adjutant` in `spec_helper.cr`, so a helper calling it is a `private def self.` inside that module.

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

---

## 5. State

Since the last handoff, four branches merged and one commit went straight to `main`:

1. **Policy ties** (#75). A tie found mid-run (H003) ends the run past any `rescue`. A tie certain from the policy alone (identical entries, or an exact entry another matches at its priority with nothing higher deciding it) is refused when the policy is built, with `InvalidRiskFlowPolicyError`.
2. **Policy regexes** (#76). Every pattern compiles its regex when built, refusing one that doesn't compile, and matches with the compiled form.
3. **Skill** (on `main`). `SKILL.md` says `cp` needs `read` for its source, and gives the `H` letter: the host's setup is at fault, so report it.
4. **Pending tests** (#77). The Windows runner enables Developer Mode, so it can create symlinks, and the symlink tests run there; the two that failed led to #78.
5. **Windows realpath** (#78). On Windows, `RealPath.resolve` asks `GetFinalPathNameByHandleW`, bound in a Windows-only `lib LibC` block, instead of Crystal's `File.realpath`, which followed only a final link. Specs take expected paths from `RealPath`, since on Windows the two now differ.

`SCOPE.md` Must Fix holds two entries: `RiskChoice` dropping effects, and the authorization configuration. Will Fix is still in the older dated style.

Model           |Latest result|Notes                                           
----------------|-------------|------------------------------------------------
qwen3.8 (27B)   |10/10        |Last sat before `fix-ruby-divergences`          
Muse Glimmer 30b|10/10        |Sat at `2bfa808`                                
Ornith 1.5 (9B) |7/10         |Sat at `2bfa808`; 02, 06 and 08 are model errors

All three predate #69, which renamed the classes the skill teaches, and the skill's `cp` and `H` lines. The next sitting is fresh, not a re-run. No current task produces an H code.

## 6. Next

1. **Sit the exam fresh** on all three models, to confirm the renamed skill.
2. **`RiskChoice` effects** (Must Fix): worst severity, union of effects; decide what `RiskSummary#path` says.
3. **`Legate::Path#under?`** (Will Fix, Legate): see §7.
4. **Exam tasks 11 to 13** (`spec/skill/TODO.md` §1). Its items 3 and 5 still call Array-keyed Hashes and slice assignment open divergences; both are fixed, so task 12 is a regression check. A credential-to-its-own-host task would now exercise risk-flow exceptions.
5. **Will Fix, style pass**, by subsection, on its own branch.
6. **Authorization configuration** (Must Fix) before 1.0, since it changes an embedder-facing format.
7. **§10, the static analyser**; see Will Fix, Static risk assessment.

## 7. Open decisions

- **D5. `Time.now`.** Core's ungated `Time.now` sits beside `Legate.now`, and `SKILL.md` both maps one to the other and whitelists `Time.now`. Keep it, fixing the skill, or bring it under U021?
- **`Legate::Path#under?`.** It doesn't resolve `..`, so it misleads a script using it as a boundary check. Logged under Will Fix, Legate. #72 settled how Adjutant judges a path (`RealPath.of`), so the remaining question is only whether to promote it to Must Fix and answer by real path too.
- **`Legate::Response` headers.** LEGATE.md §5.5 calls them frozen; Adjutant freezes only Strings. Correct §5.5, or add freezing to the backlog?
- **LEGATE.md §1** says the core is "ordinary Ruby with mutation removed". It isn't: `<<` and `[]=` mutate Arrays and Hashes. Correct it at the next spec revision.
- **`inspect` of deep data.** Printing an Array or Hash nested deeper than `call_depth_limit` (256) raises L002, since each level re-enters the VM. JSON from `fetch` may nest to 512. Make `inspect` walk built-in containers iteratively (safe, since scripts can't override their `inspect`, U003), or leave it?
- **Default budgets.** `wall_clock` 300 s, `total_read` 4 GiB, `total_write` 1 GiB and `memory` 512 MiB (advice only) are LEGATE.md §7's example values. Revisit once a harness runs real workloads.
- **Crystal's Windows `File.realpath`.** It follows only a path's final link, on `master` as in 1.20 (`src/crystal/system/win32/file.cr`). Adjutant no longer relies on it; report it upstream?
- **A suffix mode for risk-flow subjects.** Subjects match exactly or by regex. Add a dot-boundary suffix mode, like `net.hosts`' `subdomains: true`, only if policy authors keep writing the same regex.

## 8. Deferred tests

Two tests are pending on Windows only: `tree_copy_spec.cr`'s FIFO test, since Windows has no FIFOs, and `verbs/fetch_stream_spec.cr`'s raise-mid-walk test (believed a Crystal runtime defect; investigation closed).
