#!/usr/bin/env sh
# Usage: spec/skill/assemble.sh <model> [task ...]
#
# Builds runs/<model>/<task>/<task>.rb from an answer followed by the
# task's checks.rb, alongside copies of its _policy.yaml and fixtures/,
# and a link to its transcripts/ if it has one.
# Answers come from answers/<model>/<task>.rb; the model name
# "reference" uses each task's own reference.rb instead. If an answer
# contains a ``` fence, only the first fenced block is used, so a raw
# model reply can be saved as-is. With no tasks given, every task that
# has an answer is assembled.
#
# Then run: bin/debug/test_runner spec/skill/runs/<model>
set -eu

here=$(cd "$(dirname "$0")" && pwd)
model=${1:?usage: assemble.sh <model> [task ...]}
shift

if [ "$#" -eq 0 ]; then
  set -- $(ls "$here/tasks")
fi

rm -rf "$here/runs/$model"

for task in "$@"; do
  task_dir="$here/tasks/$task"
  if [ "$model" = "reference" ]; then
    answer="$task_dir/reference.rb"
  else
    answer="$here/answers/$model/$task.rb"
  fi
  [ -f "$answer" ] || { echo "skip $task: no answer"; continue; }

  out="$here/runs/$model/$task"
  mkdir -p "$out"
  cp "$task_dir/_policy.yaml" "$out/"
  [ -d "$task_dir/fixtures" ] && cp -R "$task_dir/fixtures" "$out/"
  # Linked, not copied: a transcript recorded during a run belongs in
  # the task, which is committed, not in this throwaway directory.
  [ -d "$task_dir/transcripts" ] && ln -s "$task_dir/transcripts" "$out/transcripts"

  # Keep the first fenced block if there is one, else the whole file.
  if grep -q '^```' "$answer"; then
    awk '/^```/{n++; next} n==1' "$answer" > "$out/$task.rb"
  else
    cp "$answer" "$out/$task.rb"
  fi
  printf '\n' >> "$out/$task.rb"
  cat "$task_dir/checks.rb" >> "$out/$task.rb"
  echo "built $task"
done
