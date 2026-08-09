require "sample"

# Isolation repro (see handoff discussion, 2026-08-09) for a suspected
# narrow, pre-existing compiler bug — NOT specific to native kwargs
# itself, just first exposed by it: a spec using this exact shape
# (bare, zero-positional-arg native call, wrapped in a begin/rescue
# whose rescue body is completely EMPTY) failed with an R012 "unknown
# keyword" from exec_builtin's fallback guard, meaning dispatch never
# found `remove_path` as a native method at all — as if the call fell
# through every resolution step and landed on the builtin fallback
# instead. Every other already-green spec in the suite has EITHER a
# non-empty rescue body (with a bare/native call) OR an empty rescue
# body (with a receiver-based call, `recv.attr = value` — Op::SetAttr,
# which dispatches through a completely different, isolated call path)
# — never both "zero-positional-arg Op::Call" and "empty rescue body"
# at once. This script is exactly that untested combination, run
# through the real harness rather than a spec mock, to confirm it's
# real before filing it in SCOPE.md.
#
# `remove_path(path: ...)` has ZERO positional args (argc=0 at the
# call site) — its only argument is the `path:` keyword. /etc/passwd
# is an explicit High match, DeletesFiles x High -> Reject, so this
# SHOULD be rejected and silently swallowed by the empty rescue.
#
# Expect (if the hypothesis is WRONG / no bug): the script runs to
# completion with the puts below never printing "REMOVED" — the
# rejection is caught and swallowed, same effect as
# risk_flow_kwargs_reject.rb just with an empty rescue body.
#
# Expect (if the hypothesis is RIGHT / bug is real): a Runtime error
# report for R012 "unknown keyword: `path`" instead — meaning
# `remove_path` was never even found as a native method, the same
# failure shape the spec hit.

removed = false
begin
  remove_path(path: "/etc/passwd")
  removed = true
rescue RiskFlowPolicyError => e
end
puts_args(removed ? "REMOVED (should not happen)" : "blocked, as expected")
