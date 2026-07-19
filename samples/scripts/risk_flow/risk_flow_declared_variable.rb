require "sample"

# A misleadingly-named local variable defeats every purely syntactic
# signal a human (or a naive static check) might rely on — the
# variable name says "safe", the source line gives no indication
# either. Static analysis alone can't help here (it has no way to know
# what a variable holds at runtime), and dynamic IFC's label-based
# check can't help either (safe_file is a plain script-level string
# literal — nothing ever attaches a label to it, regardless of what
# it's named).
#
# What actually catches this is the same mechanism as
# risk_flow_declared_literal.rb: delete_file declares sensitivity on
# its argument's literal CONTENT, not on whatever label (if any) the
# Value happens to carry. The variable's name is irrelevant; the
# string "/etc/passwd" is what gets checked, wherever it came from.

safe_file = "/etc/passwd"
#
# ... other lines and code before we get to the call below, so a
# reviewer skimming the call site alone (or a tool that only looks at
# argument literals, not variable contents) would have no reason to
# suspect this variable's actual value.
#
begin
  delete_file(safe_file)
  puts_args("deleted #{safe_file} (should not happen)")
rescue RiskFlowPolicyError => e
  puts_args("blocked by risk flow policy: #{e.message}")
end
