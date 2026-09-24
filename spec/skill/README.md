# Skill exam

Tests whether a model can write working Adjutant scripts from `skills/adjutant/SKILL.md` alone. The model writes an answer; our checks mark it; the script runner decides pass or fail.

## Layout

```
spec/skill/
  PREAMBLE.md            rules sent with every task
  skill_spec.cr          keeps SKILL.md in step with the runtime (runs under `crystal spec`)
  assemble.sh            answer + checks → runnable script
  tasks/NN_name/
    TASK.md              the contract the model sees
    checks.rb            assertions the model never sees
    _policy.yaml         grants only what the task needs
    fixtures/            input files
    transcripts/         recorded HTTP for tasks that fetch (linked, not copied)
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

A task that fetches needs its transcript recorded once: assemble `reference` and run it with `WIRETAP_RECORD=1`, then commit what appears in the task's `transcripts/`. Model runs replay it, so an answer that requests a different URL or method fails.

## Adding a task

Each task should test one skill. The contract in `TASK.md` fixes the method name, parameters and return value exactly, because `checks.rb` calls it. Grant the least the task needs in `_policy.yaml`: an answer that reaches for more should fail with `Legate::Denied`.

## Keeping the skill current

`skill_spec.cr` fails when `SKILL.md` misses a Legate verb, names one that does not exist, or has no decision for a U-code in `UNSUPPORTED.md`. For a new U-code, either add a redirect to the skill and its phrase to `SKILL_COVERED_U_CODES`, or add it to `SKILL_OMITTED_U_CODES` with the reason.

## Results

Skill commit                  |Model           |Passed                      |Notes                                                                                                                                                                                                                                                                                                                                                               
------------------------------|----------------|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
`a7db0de`                     |qwen3.8 (27B)   |3/4 tasks (13/17 assertions)|02 sorted `[-count, word]` pairs; Arrays don't compare, so the order was wrong. Skill was silent; runtime answered wrongly without error (SCOPE.md).                                                                                                                                                                                                                
`a7db0de` + Array-compare note|qwen3.8 (27B)   |02 re-sat: pass             |Built a single sortable key: zero-padded `max - count`, then the word. Correct, but 20 lines where Ruby needs one; evidence for fixing Array comparison.                                                                                                                                                                                                            
`f03764b`                     |Muse Glimmer 30b|3/4 tasks                   |02 prefixed a padded count with `"-"`, as if String negation reversed the order; it doesn't, so words came out least frequent first. Took minutes on 02, seconds on the rest. Second model to struggle with the same workaround.                                                                                                                                    
`1a49f3b`                     |qwen3.8 (27B)   |4/4 tasks                   |02 in under 50s: `counts.to_a` then `sort_by` on `[-pair[1], pair[0]]`, the idiomatic answer, first try.                                                                                                                                                                                                                                                            
`1a49f3b`                     |Muse Glimmer 30b|4/4 tasks                   |02 in ~90s, down from minutes. Same `sort_by` key, but built the pairs with `each` rather than `Hash#to_a`.                                                                                                                                                                                                                                                         
`c90d591`                     |qwen3.8 (27B)   |9/9 tasks                   |First sitting of 05–09; no failures, so nothing to classify.                                                                                                                                                                                                                                                                                                        
`c90d591`                     |Muse Glimmer 30b|9/9 tasks                   |First sitting of 05–09; no failures, so nothing to classify.                                                                                                                                                                                                                                                                                                        
pre-`a22ebbf`                 |Ornith 1.5 (9B) |6/10 tasks                  |Sat with a copy of the skill older than `a22ebbf`, whose Path and counting lines answer 01 and 05; re-sit pending. 01 `counts[w] += 1` on a missing key; 04 omitted `format:`; 05 `entry.path.split`, assuming a String; 08 retried after a success; 09 answer didn't parse. 10 passed after `41ef814`.                                                             
`a22ebbf`                     |qwen3.8 (27B)   |10/10 tasks                 |Runtime at `41ef814`. First sitting of 10; no failures.                                                                                                                                                                                                                                                                                                             
`a22ebbf`                     |Muse Glimmer 30b|10/10 tasks                 |Runtime at `41ef814`. First sitting of 10; no failures.                                                                                                                                                                                                                                                                                                             
`a22ebbf`                     |Ornith 1.5 (9B) |4/10 tasks, then 6/10       |01 and 05's previous failures gone. Two Adjutant defects, fixed: 02 gave `sort_by` two block parameters and got `nil` for the second, since blocks didn't spread an Array (`c9f5951`); 05 and 10 `next unless` parsed as a value (`a0541d8`). Model: 03 took no maximum; 04 `Array#index`; 08 gave up before the last attempt; 10 `&blk`, then U001. No skill edits.
