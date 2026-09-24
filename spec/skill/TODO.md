# Exam backlog

Work planned for the exam and the drift spec, in rough priority order. Remove an entry when it lands; the commit log keeps the history. Runtime defects go to [SCOPE.md](../../SCOPE.md), not here.

## 1. Tasks 11 to 13: tooling scripts

Tasks 01 to 10 no longer discriminate: two models score 10/10. These three come from scripts written to do real work (the 2026-09 comment cleanup of `src/`), not to test anyone, which is the kind of script Adjutant exists to run. Their sources are in §4.

Task|Function                                                                                                            |Source             
----|--------------------------------------------------------------------------------------------------------------------|-------------------
11  |`comment_blocks(path)` returns each run of full-line comments as `[first, last, next_code_line]`                    |`blocks.py`        
12  |`replace_lines(path, edits)` applies line-range replacements bottom-up, raising if a range covers a non-comment line|`relines.py`       
13  |`code_unchanged?(before, after)` compares two files' non-comment lines and `# ameba:` directives                    |`code_unchanged.sh`

1. **Inputs are paths, not commands.** Task 13's source runs `git show HEAD:file`; Legate has no process verb (U021), so the task takes two files. That is the pattern a harness uses anyway: it supplies what a script would otherwise shell out for.
2. **Fixtures carry the edge cases:** a trailing comment, a line starting with `#` inside a heredoc, an ameba directive, blank lines inside a comment block, and a file ending in a comment.
3. **Expect Adjutant defects, not only model errors.** The natural translation of task 12 keys a Hash by `[first, last]` pairs and assigns into a slice, both Must Fix divergences in SCOPE.md. A model that follows the skill ("Arrays do not slice by Range") writes around the slice and never triggers it; record which it did.
4. **Report these tasks separately in README.md's results**, so the 10/10 baseline on 01 to 10 stays comparable.
5. **Write the tasks before fixing the divergences they touch**, so a failure is the evidence for the fix.

## 2. Harder tasks from the 2026-09-24 handoff

Only if the skill needs to serve larger models better. Put any extra depth in reference files that `SKILL.md` points to, not in `SKILL.md` itself.

1. A multi-step script that combines several verbs.
2. A single-pass stream: read once, aggregate, never buffer.
3. Recovery from `Legate::TooLarge`.
4. A policy denial: the task needs a grant `_policy.yaml` withholds, and the check expects the error to be handled or reported, not faked around.

## 3. Drift spec

1. **Check the method whitelist.** Extend `skill_spec.cr` to assert that every method `SKILL.md` §3 lists exists on its class; about 20 lines. A wrong whitelist is the most harmful way for the skill to go stale.

## 4. Source scripts

Kept here so they survive between sessions. The workflow they served:

1. `blocks.py file [lo] [hi]` lists each comment block with the code line after it.
2. Read each block against that code, and check DEVELOPMENT.md before deleting any rationale.
3. Write an edits file, `E = {(first, last): "replacement\n", ...}`, against the original line numbers.
4. Assert every line in every range is a comment, then apply with `relines`.
5. `code_unchanged.sh file` confirms code and directives match HEAD.

The checker's blind spots: it treats only full-line comments as comments, so it fails on an edited trailing comment; a `#` line inside a string or heredoc counts as a comment, so a change there would pass; and it knows no magic comments other than `# ameba:`.

### blocks.py

```python
import sys, re

path = sys.argv[1]
lo = int(sys.argv[2]) if len(sys.argv) > 2 else 1
hi = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9
lines = open(path).read().split('\n')
i = 0
while i < len(lines):
    if re.match(r'^\s*#', lines[i]):
        start = i
        while i < len(lines) and re.match(r'^\s*#', lines[i]):
            i += 1
        if lo <= start + 1 <= hi:
            print(f"=== {start + 1}-{i} ({i - start})")
            for k in range(start, i):
                print(f"{k + 1}: {lines[k]}")
            print(f"   >> {lines[i] if i < len(lines) else ''}")
    else:
        i += 1
```

### relines.py

```python
def relines(path, edits):
    """Replaces 1-indexed inclusive line ranges: {(first, last): text}.
    Applied bottom-up, so every range refers to the original numbering.
    An empty or blank text deletes the range."""
    lines = open(path).read().split('\n')
    for (first, last), new in sorted(edits.items(), reverse=True):
        replacement = new.rstrip('\n').split('\n') if new.strip() else []
        lines[first - 1:last] = replacement
    open(path, 'w').write('\n'.join(lines))
```

### code_unchanged.sh

```bash
#!/bin/bash
# Usage: code_unchanged.sh <file>...
# Fails if any non-comment line, or any ameba directive, differs from HEAD.
rc=0
for f in "$@"; do
  strip() { grep -vE '^\s*(#.*)?$'; }
  directives() { grep -E '^\s*#\s*ameba:'; }
  if ! diff <(git show HEAD:"$f" | strip) <(strip < "$f") >/dev/null; then
    echo "CODE CHANGED: $f"; rc=1
  elif ! diff <(git show HEAD:"$f" | directives) <(directives < "$f") >/dev/null; then
    echo "DIRECTIVE CHANGED: $f"; rc=1
  else
    echo "ok: $f"
  fi
done
exit $rc
```
