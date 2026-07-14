require "sample"

# This script never calls read_file at all — it passes a plain string
# literal straight to delete_file. Nothing ever attaches a
# RiskFlowLabel to a script-level literal, so VM#call_native's
# automatic, label-driven check has nothing to see here: this call
# would go through completely unnoticed if delete_file relied only on
# inherited labels.
#
# What actually catches this: delete_file calls
# ncc.declare_sensitivity(DeletesFiles, File, path) on its own argument
# directly (see run_script.cr's SampleModule) — consulting policy on
# the path's literal content regardless of whether anything labeled it.
# /etc/passwd is an explicit High-sensitivity exact match in the sample
# policy, and DeletesFiles x High -> Reject, so this is rejected the
# same way risk_flow_reject.rb's delete_file("/etc/passwd") call is —
# just with no read_file call anywhere in this script at all.

begin
  delete_file("/etc/passwd")
  puts_args("deleted /etc/passwd (should not happen)")
rescue RiskFlowPolicyError => e
  puts_args("blocked by risk flow policy: #{e.message}")
end
