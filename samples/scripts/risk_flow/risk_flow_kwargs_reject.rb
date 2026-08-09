require "sample"

# Native keyword argument support (2026-08-09): a labeled value passed
# as a KEYWORD argument to a risk-tagged native call must be enforced
# exactly like a positional one. Before this session, native calls
# unconditionally rejected any kwargs at all, so this path was
# unreachable; VM#check_risk_flow now scans `kwargs` values for labels
# too, not just `args` — this script is that check exercised for
# real, not just in a spec.
#
# `delete_file`'s risky argument is normally its POSITIONAL `path` —
# here the path itself is clean (/tmp/scratch.txt, an explicit None
# match in the sample policy), and the taint arrives ONLY via the
# optional `reason:` keyword argument, which delete_file does nothing
# with except log — a clean isolation of "does a labeled kwarg VALUE
# alone trip the automatic label-driven check," independent of
# declare_sensitivity (which only ever looks at the positional path).
#
# Expect: rejected — caught by the script, same shape as
# risk_flow_reject.rb's positional-argument rejection.

secrets = read_file("/etc/passwd")

begin
  delete_file("/tmp/scratch.txt", reason: secrets)
  puts_args("deleted /tmp/scratch.txt (should not happen)")
rescue RiskFlowPolicyError => e
  puts_args("blocked by risk flow policy: #{e.message}")
end
