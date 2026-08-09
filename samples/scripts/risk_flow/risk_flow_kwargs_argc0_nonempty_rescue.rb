require "sample"

# Control/contrast case for risk_flow_kwargs_argc0_empty_rescue.rb —
# IDENTICAL call shape (remove_path(path: ...), argc=0, no positional
# args), the ONLY difference is a non-empty rescue body (a single
# `puts_args` call), matching every other already-green spec's
# begin/rescue-around-a-bare-call shape.
#
# Expect: rejected and caught normally — "blocked by risk flow
# policy: ..." printed from inside the rescue body, same as
# risk_flow_kwargs_reject.rb. If THIS script behaves correctly while
# risk_flow_kwargs_argc0_empty_rescue.rb does not, that confirms the
# empty-rescue-body + argc=0 combination specifically, not native
# kwargs or argc=0 alone.

begin
  remove_path(path: "/etc/passwd")
  puts_args("removed /etc/passwd (should not happen)")
rescue RiskFlowPolicyError => e
  puts_args("blocked by risk flow policy: #{e.message}")
end
