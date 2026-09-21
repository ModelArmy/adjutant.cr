# Skill exam

Tests whether a model can write working Adjutant scripts from `skills/adjutant/SKILL.md` alone. The model writes an answer; our checks mark it; the script runner decides pass or fail.

## Layout

```
spec/skill/
  PREAMBLE.md            rules sent with every task
  assemble.sh            answer + checks → runnable script
  tasks/NN_name/
    TASK.md              the contract the model sees
    checks.rb            assertions the model never sees
    _policy.yaml         grants only what the task needs
    fixtures/            input files
    reference.rb         a known-good answer, to validate the task itself
  answers/<model>/       model replies (gitignored)
  runs/<model>/          assembled scripts (gitignored)
```

## Sitting the exam

One task per prompt, so one failure cannot contaminate the next.

1. Send the model, in order: `PREAMBLE.md`, `skills/adjutant/SKILL.md`, then the task's `TASK.md`.
2. Save the reply verbatim as `answers/<model>/<task>.rb`. Surrounding prose and code fences are fine; the assembler keeps only the first fenced block.

## Marking

1. `spec/skill/assemble.sh <model>`
2. `bin/debug/test_runner spec/skill/runs/<model>`
3. Record the result below. For each failure, note its cause: the skill was wrong, the skill was silent, or the model ignored it.

Validate a new or changed task first with `assemble.sh reference`; its reference answer must pass.

## Adding a task

Each task should test one skill. The contract in `TASK.md` fixes the method name, parameters and return value exactly, because `checks.rb` calls it. Grant the least the task needs in `_policy.yaml`: an answer that reaches for more should fail with `Legate::Denied`.

## Results

Skill commit|Model|Passed|Notes
------------|-----|------|-----
