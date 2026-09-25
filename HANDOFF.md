# Handoff

Working notes between development sessions, kept current by whoever ends a session. Not user documentation.

Last updated at the end of the `cleaning-up-the-repo` branch, before its merge to `main`.

## How to use this document

Sections marked **[Retain]** carry forward unchanged unless a convention in them changes; when one does, edit it in place. The other sections describe the current state and are rewritten at the end of each session, in the same commit as the session's last work. The commit log is the history, so this file keeps none.

On arrival, check this document against the repo before proposing work: branch names, commit claims and "done" statements can be wrong.

---

## 1. The project [Retain]

Adjutant is a subset of Ruby implemented in Crystal (parser → compiler → bytecode VM). It is meant for models to write, and an agent harness assesses a script's risk before running it in secure environments. **Legate** is its capability-based standard library: the only way a script touches files, the network or the environment, and only as far as its policy grants.

`skills/adjutant/SKILL.md` teaches a model to write Adjutant. The exam in `spec/skill/` measures whether it works; `spec/skill/README.md` records every sitting and is the evidence behind every line of the skill.

Key documents: `SCOPE.md` (known defects and gaps: Must Fix, Will Fix), `LEGATE.md` (Legate's spec, with a status table), `UNSUPPORTED.md` (U-codes, deliberate exclusions), `ERRORS.md` (diagnostic catalog), `DEVELOPMENT.md` (how the code works, for contributors), `spec/skill/TODO.md` (exam backlog, and the comment-cleanup scripts).

## 2. Working conventions [Retain]

1. **Division of work.** Claude clones the repo and presents edited files for review; the human saves, tests, commits and pushes. Up to ten files, present the files; over ten, one patch per commit. Claude sets up no toolchain. Claude proposes a one-line commit message when a change is ready.
2. **Pull before delivering.** Pull at the start of a turn and again just before building the files or patches, since the human may push in between.
3. **Branches.** Runtime fixes go on a sub-branch or directly on the working branch, at the human's call. Either way, a commit never mixes Crystal changes with exam or skill changes.
4. **`SCOPE.md` entries are removed when resolved**, not marked resolved. History belongs in the commit log; rationale goes in `DEVELOPMENT.md` only when a future contributor needs it.
5. **Comments and docs describe the current state.** Code comments document how to use an API and what a type or function produces; inside a function, the steps it takes. No dates, no change history, no "previously". Keep a short "why" only where it stops someone undoing a deliberate choice.
6. **Comment-only changes are verified mechanically**: every non-comment line, and every `# ameba:` directive, identical to HEAD (`code_unchanged.sh`, in `spec/skill/TODO.md` §4).
7. **State a convention's reasons accurately.** Don't dress a convention up as a guarantee the project never made, or a future contributor will defend a property nobody promised.
8. **Test-harness errors do not belong in the error catalog.** Mistakes in a spec raise plain `RuntimeError`s, not R-codes.
9. **Never `git reset --hard` with uncommitted work in the tree.**
10. **Markdown tables:** no literal `|` inside a cell; reword instead.

## 3. The evidence method [Retain]

1. **Adjutant is a proper subset of Ruby.** Anything it accepts and then runs differently from Ruby is a Must Fix defect, however rare; rejecting a construct Ruby accepts is only a gap. Adding a method or form Ruby lacks also breaks the subset.
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
7. **A verifier that can't fail proves nothing.** The comment checker passed on a nonexistent path, because empty equals empty; it now checks existence. Give every check a case it must reject.

---

## 5. State

The `cleaning-up-the-repo` branch rewrote the comments in `src/` (12,937 comment lines to 3,700) and the contributor docs to describe the current state. Reading every file closely for that found about 30 defects, and the subset rule (§3.1) promoted six older gaps; Must Fix went from 9 entries to 45. None has been fixed: Adjutant is not in general use, and fixing waits for its own session.

Model           |Latest result|Notes                          
----------------|-------------|-------------------------------
qwen3.8 (27B)   |10/10        |At the exam's ceiling          
Muse Glimmer 30b|10/10        |At the exam's ceiling          
Ornith 1.5 (9B) |6/10         |03, 04, 08, 10 are model errors

These sittings predate one skill edit: the Float whitelist was wrong (the census missed macro-registered methods), and `SKILL.md` now lists `round`, `floor`, `ceil`, `truncate`, `abs`, `finite?` and `nan?`.

## 6. Next

1. **Verify the older Must Fix entries.** The last eight or so in Must Fix predate this branch, and some describe states the code has moved past: the entry saying `check_risk_flow` is connected to no verb (16 verbs now declare authorities), and the one about moving authorization to core, which has since happened. Remove what's resolved and rewrite what's left in the current style.
2. **Fix Must Fix, security first.** The first twelve entries are security and policy defects, led by two perimeter escapes (a recursive `cp` following symlinks, and `append` writing through a dangling symlink). For each: a spec that hits it, then the fix. The symlink specs can't run on Windows CI; skip them there, as `authorization_spec.cr`'s symlinked-root test already is.
3. **Then the Ruby divergences**, the next 25 entries, in the order that shares work: arity (script and native together), Hash key semantics (Integer and Float, and containers), indexing shapes, then the rest.
4. **Exam tasks 11 to 13** (`spec/skill/TODO.md` §1) before fixing the divergences they touch, so their failures are the evidence.
5. **§10, the static analyser**, after Must Fix. It begins with a design question: what counts as the "effectful surface" (the note under Must Fix's §10 entry).

## 7. Open decisions

- **D5. `Time.now`.** Core's ungated `Time.now` sits beside `Legate.now`, and `SKILL.md` both maps one to the other and whitelists `Time.now`. Keep it, fixing the skill, or bring it under U021?
- **D11. A policy `default:` helper.** Completing risk-flow policies (Must Fix) touches about 45 construction sites. A helper filling unlisted pairs with one stated action would keep specs short, but reintroduces a default.
- **`Legate::Path#under?`.** It doesn't resolve `..`, so it misleads a script using it as a boundary check. Logged under Will Fix, Legate; promote to Must Fix?
- **`Legate::Response` headers.** LEGATE.md §5.5 calls them frozen; Adjutant has no freezing. Correct §5.5, or add freezing to the backlog?
- **LEGATE.md §1** says the core is "ordinary Ruby with mutation removed". It isn't: `<<` and `[]=` mutate. Correct it at the next spec revision.

## 8. Deferred tests

`authorization_spec.cr`'s symlinked-root test (Windows CI cannot create symlinks) and `verbs/fetch_stream_spec.cr`'s raise-mid-walk test (believed a Crystal runtime defect; investigation closed).
