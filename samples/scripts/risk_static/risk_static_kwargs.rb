require "sample"

# Native keyword argument support (2026-08-09) exposed a real,
# pre-existing static-analysis gap: RiskWalker#walk_call never walked
# `node.kwargs` at all — only `node.args` — so a risky call sitting in
# a keyword-argument position was completely invisible to the static
# pass, even though the exact same call in a POSITIONAL slot was
# already caught (fixed 2026-07-18). This script is the minimal case:
# `remove_path` itself takes no risky positional args at all — its
# ONLY argument is the `path:` keyword — so if walk_call's kwargs fix
# is wrong or missing, the static pass below would report NO risk at
# all for this script, which would be a real, silent miss.
#
# Expect: "=== Static risk assessment ===" reports DeletesFiles /
# Severity::Error — the same as risk_static_01.rb's bare
# `delete_file()` call reports, just reached through a kwarg instead
# of a positional arg.

def cleanup(target)
  remove_path(path: target)
end

cleanup("/tmp/scratch.txt")
