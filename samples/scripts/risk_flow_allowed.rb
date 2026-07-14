require "sample"

# /tmp/scratch.txt is explicitly None sensitivity in the sample policy —
# reading it and posting its contents externally never triggers a risk
# flow check at all, since action_for's None short-circuit means the
# policy's risk_flow_rules table is never even consulted. No prompt, no
# pause. delete_file("/tmp/scratch.txt") is included too, deleting the
# actual path this time (not its contents) — also unchecked, since the
# path itself is None sensitivity.
#
# Compare with risk_flow_ask.rb (Elevated -> Ask) and
# risk_flow_reject.rb (High -> Reject): same call shapes, different
# sensitivity on the values involved, different outcome.

contents = read_file("/tmp/scratch.txt")
puts_args(contents)

post_data("https://example.com/upload", contents)

delete_file("/tmp/scratch.txt")
