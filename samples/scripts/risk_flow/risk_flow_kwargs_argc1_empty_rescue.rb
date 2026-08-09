require "sample"

# Second control/contrast case for risk_flow_kwargs_argc0_empty_rescue.rb
# — same EMPTY rescue body, but the call now has ONE positional
# argument (argc=1, delete_file's ordinary path arg) instead of zero,
# no kwargs at all. Isolates whether "empty rescue body" is ever a
# problem on its own for a bare/native call (independent of argc=0 or
# kwargs) — the existing green `Box.new.value = ...` spec already
# proves empty rescue bodies are fine for a RECEIVER-based call, but
# nothing already-green tests empty rescue + a bare/native Op::Call
# specifically until this script and its argc=0 sibling.
#
# Expect: rejected and swallowed silently, same shape as
# risk_flow_kwargs_argc0_empty_rescue.rb's "if hypothesis is WRONG"
# case — if THIS script behaves correctly (blocked, no crash, no
# R012) while the argc=0 sibling does not, that pins the bug on
# argc=0 specifically, not empty-rescue-with-a-bare-call in general.

removed = false
begin
  delete_file("/etc/passwd")
  removed = true
rescue RiskFlowPolicyError => e
end
puts_args(removed ? "DELETED (should not happen)" : "blocked, as expected")
